import { getEngineInfo, slice } from 'libcuraslicer.so';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { mediaquery } from '@kit.ArkUI';
import { SlicerSetting, createDefaultSettings } from '../model/SlicerSetting';
import { APP_NAME } from '../model/AppInfo';
import { SettingsPanel } from '../view/SettingsPanel';
import { PrinterPanel } from '../view/PrinterPanel';
import { AboutDialog } from '../view/AboutDialog';
import { UsbPrinterService } from '../service/UsbPrinterService';
import { Mesh3mf } from '../service/Mesh3mf';
import { DeviceProfile } from '../model/DeviceProfile';
import { SceneObject, SceneStore } from '../model/SceneModel';
import { ProjectStore } from '../service/ProjectStore';
import { ModelPanel } from '../view/ModelPanel';

const DOMAIN = 0x0000;

@Entry
@Component
struct Index {
  @State settings: SlicerSetting[] = createDefaultSettings();
  @State printer: UsbPrinterService = new UsbPrinterService();
  @State gcodePath: string = '';
  @State status: string = '就绪';
  @State modelName: string = 'cube.stl（内置示例）';
  @State engineInfo: string = '';
  @State logTail: string = '';
  @State slicing: boolean = false;
  @State importing: boolean = false;
  @State moveMode: boolean = false;
  // Responsive layout: phone (small) shows the preview full width with a collapsible bottom panel,
  // tablet keeps two columns with a narrower sidebar, 2in1 uses the desktop sidebar.
  @State isSmall: boolean = false;
  @State isMedium: boolean = false;
  @State showSidePanel: boolean = false;
  //! Modelling scene: objects placed on the build plate (see ModelPanel / SceneModel).
  @State scene: SceneObject[] = [];
  @State selectedIndex: number = 0;
  @State sceneVersion: number = 0;
  //! Undo/redo stacks of scene snapshots (deep copies, so no JSON parsing is needed to restore).
  private history: SceneObject[][] = [];
  private redoHistory: SceneObject[][] = [];

  private smallQuery: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(width<600vp)');
  private mediumQuery: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(600vp<=width<840vp)');

  //! What this device is and which features it can use (see DeviceProfile).
  private device: DeviceProfile = new DeviceProfile();

  private aboutController: CustomDialogController = new CustomDialogController({
    builder: AboutDialog(),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    // Use the dialog's own layout: the default container is narrower than this content and clips it.
    customStyle: true
  });

  aboutToAppear(): void {
    this.engineInfo = getEngineInfo();
    this.gcodePath = `${getContext(this).filesDir}/cube.gcode`;
    if (this.device.supportsPrinting) {
      // Ports are only relevant where USB printing exists.
      this.printer.refreshPorts();
    }
    try {
      const context = getContext(this);
      // The native preview reads cube.stl from the sandbox, so seed it before the XComponent
      // surface is created.
      this.materialiseRawFile('models/cube.stl', `${context.filesDir}/cube.stl`);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'CuraSlice', 'MODEL_PREP_FAIL reason=%{public}s', err.message);
    }
    this.refreshLog();
    this.persistViewMode();
    // Any setting edit may change the machine build volume, which the preview mirrors.
    this.settings.forEach((item: SlicerSetting): void => {
      item.onChanged = (): void => {
    this.persistPlateSize();
    // Default scene: the bundled sample model, so the preview has content before any edit and the
    // native side can export scene.stl for slicing.
    if (this.scene.length === 0) {
      this.scene = [new SceneObject('imported', '示例模型', 0)];
      this.selectedIndex = 0;
      this.commitScene();
    }
      };
    });
    this.persistPlateSize();
    // Responsive breakpoints: <600vp phone, 600..840vp tablet, else desktop.
    this.smallQuery.on('change', (result: mediaquery.MediaQueryResult): void => {
      this.isSmall = result.matches;
    });
    this.mediumQuery.on('change', (result: mediaquery.MediaQueryResult): void => {
      this.isMedium = result.matches;
    });
    this.isSmall = this.smallQuery.matches;
    this.isMedium = this.mediumQuery.matches;
    hilog.info(DOMAIN, 'CuraSlice', 'DEVICE kind=%{public}s serial=%{public}s', this.device.kind, `${this.device.supportsSerial}`);
  }

  aboutToDisappear(): void {
    this.smallQuery.off('change');
    this.mediumQuery.off('change');
  }

  // Privacy is handled by the platform's hosted privacy statement (AGC 隐私托管). The app must NOT
  // show its own consent dialog, otherwise the first launch pops two privacy dialogs and review
  // rejects it. The hosted policy is linked from the "关于" dialog instead.

  private filesDir(): string {
    return getContext(this).filesDir;
  }

  // Writes the scene for the native renderer without touching the undo history.
  private writeScene(): void {
    SceneStore.persist(this.filesDir(), this.scene);
    this.sceneVersion++;
  }

  // Every user-visible edit goes through here so it can be undone.
  private commitScene(): void {
    this.writeScene();
    this.history.push(this.snapshot());
    if (this.history.length > 50) {
      this.history.shift();
    }
    this.redoHistory = [];
  }

  private snapshot(): SceneObject[] {
    return this.scene.map((item: SceneObject): SceneObject => item.clone());
  }

  private undo(): void {
    if (this.history.length < 2) {
      this.status = '没有可撤销的操作';
      return;
    }
    const current: SceneObject[] = this.history[this.history.length - 1];
    this.history.pop();
    this.redoHistory.push(current);
    this.scene = this.history[this.history.length - 1];
    this.selectedIndex = this.scene.length > 0 ? Math.min(this.selectedIndex, this.scene.length - 1) : -1;
    this.writeScene();
    this.status = '已撤销';
  }

  private redo(): void {
    if (this.redoHistory.length === 0) {
      this.status = '没有可重做的操作';
      return;
    }
    const next: SceneObject[] = this.redoHistory[this.redoHistory.length - 1];
    this.redoHistory.pop();
    this.history.push(next);
    this.scene = next;
    this.selectedIndex = this.scene.length > 0 ? this.scene.length - 1 : -1;
    this.writeScene();
    this.status = '已重做';
  }

  private async saveProject(): Promise<void> {
    const uri: string = await ProjectStore.saveText(getContext(this), 'SliceForge.sfproj', ProjectStore.serialize(this.scene));
    this.status = uri === '' ? '已取消保存' : '工程已保存';
  }

  private async openProject(): Promise<void> {
    const path: string = await ProjectStore.pickToSandbox(getContext(this), this.filesDir());
    if (path === '') {
      this.status = '已取消打开';
      return;
    }
    const opened: SceneObject[] = ProjectStore.parse(ProjectStore.readText(path));
    if (opened.length === 0) {
      this.status = '工程文件为空或格式不支持';
      return;
    }
    this.scene = opened;
    this.selectedIndex = 0;
    this.commitScene();
    this.status = `已打开工程（${opened.length} 个对象）`;
  }

  private async exportStl(): Promise<void> {
    const scenePath: string = `${this.filesDir()}/scene.stl`;
    if (!fs.accessSync(scenePath)) {
      this.status = '还没有可导出的网格';
      return;
    }
    const uri: string = await ProjectStore.saveFile(getContext(this), 'SliceForge.stl', scenePath);
    this.status = uri === '' ? '已取消导出' : '已导出 STL';
  }

  private async export3mf(): Promise<void> {
    const scenePath: string = `${this.filesDir()}/scene.stl`;
    if (!fs.accessSync(scenePath)) {
      this.status = '还没有可导出的网格';
      return;
    }
    this.status = '正在导出 3MF…';
    const zipPath: string = await ProjectStore.export3mf(this.filesDir(), scenePath);
    if (zipPath === '') {
      this.status = '导出 3MF 失败';
      return;
    }
    const uri: string = await ProjectStore.saveFile(getContext(this), 'SliceForge.3mf', zipPath);
    this.status = uri === '' ? '已取消导出' : '已导出 3MF';
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  // Boolean runs in the native renderer (no direct call is possible): write bool.req, then poll for
  // bool.done. A = the object above the selected one, B = the selected object.
  private async runBoolean(operation: string): Promise<void> {
    if (this.scene.length < 2 || this.selectedIndex <= 0) {
      this.status = '布尔运算：请选中第二个对象（结果 = 上一个与选中的对象）';
      return;
    }
    const indexB: number = this.selectedIndex;
    const indexA: number = indexB - 1;
    const dir: string = this.filesDir();
    const donePath: string = `${dir}/bool.done`;
    try {
      fs.unlinkSync(donePath);
    } catch (error) {
      // No previous result: nothing to remove.
    }
    try {
      const request = fs.openSync(`${dir}/bool.req`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(request.fd, `${operation} ${indexA} ${indexB}`);
      } finally {
        fs.closeSync(request);
      }
    } catch (error) {
      const err = error as BusinessError;
      this.status = `布尔请求失败：${err.message}`;
      return;
    }

    this.status = '布尔运算中…';
    const deadline: number = Date.now() + 20000;
    while (Date.now() < deadline) {
      await this.sleep(200);
      if (fs.accessSync(donePath)) {
        const label: string = operation === 'union' ? '并集' : (operation === 'subtract' ? '差集' : '交集');
        const result = new SceneObject('mesh', label, 0);
        result.file = 'boolean.stl';
        this.scene.splice(indexA, 2);
        this.scene.push(result);
        this.selectedIndex = this.scene.length - 1;
        this.commitScene();
        this.status = `布尔${label}完成`;
        hilog.info(DOMAIN, 'CuraSlice', 'BOOLEAN_OK op=%{public}s', operation);
        return;
      }
    }
    this.status = '布尔运算超时（请重试）';
  }

  // The native preview cannot be called from ArkTS (the XComponent loads it), so the drag mode is
  // handed over through a one-word sandbox file that the renderer reads when a gesture starts.
  private persistViewMode(): void {
    try {
      const file = fs.openSync(`${this.filesDir()}/view_mode`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, this.moveMode ? 'translate' : 'rotate');
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'CuraSlice', 'VIEW_MODE_FAIL reason=%{public}s', err.message);
    }
  }

  private findSettingValue(key: string, fallback: number): number {
    const found: SlicerSetting | undefined = this.settings.find((item: SlicerSetting): boolean => item.key === key);
    return found !== undefined ? found.value : fallback;
  }

  // Mirrors the machine build volume into the sandbox so the preview plate resizes with the settings.
  private persistPlateSize(): void {
    const width: number = this.findSettingValue('machine_width', 200);
    const depth: number = this.findSettingValue('machine_depth', 200);
    try {
      const file = fs.openSync(`${this.filesDir()}/plate_size`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, `${width} ${depth}`);
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'CuraSlice', 'PLATE_SIZE_FAIL reason=%{public}s', err.message);
    }
  }

  private materialiseRawFile(rawName: string, targetPath: string): void {
    const context = getContext(this);
    const data: Uint8Array = context.resourceManager.getRawFileContentSync(rawName);
    const file = fs.openSync(targetPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data.buffer);
    } finally {
      fs.closeSync(file);
    }
  }

  private readTail(path: string, count: number): string {
    try {
      if (!fs.accessSync(path)) {
        return '';
      }
      const lines: string[] = fs.readTextSync(path).split('\n').filter((line: string): boolean => line.length > 0);
      return lines.slice(-count).join('\n');
    } catch (error) {
      const err = error as BusinessError;
      return `读取失败：${err.message}`;
    }
  }

  private refreshLog(): void {
    this.logTail = this.readTail(`${this.filesDir()}/curaengine.log`, 4);
  }

  private async importModel(): Promise<void> {
    if (this.importing || this.slicing) {
      return;
    }
    this.importing = true;
    try {
      const documentPicker = new picker.DocumentViewPicker(getContext(this));
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      // No fileSuffixFilters: the system picker only honours ONE custom suffix, so listing both hid
      // every .stl file once 3MF support was added. The extension is validated below instead.
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const name: string = uris[0].split('/').pop() ?? 'model.stl';
      const lowerName: string = name.toLowerCase();
      if (!lowerName.endsWith('.stl') && !lowerName.endsWith('.3mf')) {
        this.status = '请选择 STL 或 3MF 文件';
        return;
      }
      const dir: string = this.filesDir();
      const modelPath: string = `${dir}/cube.stl`;

      if (lowerName.endsWith('.3mf')) {
        // 3MF is a zip archive; flatten it to a binary STL that the preview and CuraEngine accept.
        // zlib.decompressFile requires the source extension to be .zip, hence the .zip temp name.
        this.status = '正在解析 3MF…';
        const zipPath: string = `${dir}/import_tmp.zip`;
        this.copyPickedFile(uris[0], zipPath);
        const triangles: number = await Mesh3mf.convertToStl(zipPath, dir, modelPath);
        this.modelName = name;
        this.status = `已导入 ${name}（${triangles} 个三角面）`;
      } else {
        this.copyPickedFile(uris[0], modelPath);
        this.modelName = name;
        this.status = `已导入 ${name}`;
      }
      // The imported geometry becomes the whole scene; the native side re-parses cube.stl and
      // re-exports scene.stl from it.
      this.scene = [new SceneObject('imported', name, 0)];
      this.selectedIndex = 0;
      this.commitScene();
    } catch (error) {
      const err = error as BusinessError;
      this.status = `导入失败：${err.message}`;
      hilog.error(DOMAIN, 'CuraSlice', 'IMPORT_FAIL reason=%{public}s', err.message);
    } finally {
      this.importing = false;
    }
  }

  private copyPickedFile(uri: string, targetPath: string): void {
    const source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const target = fs.openSync(targetPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(source.fd, target.fd);
      } finally {
        fs.closeSync(target);
      }
    } finally {
      fs.closeSync(source);
    }
  }

  private runSlice(): void {
    if (this.slicing || this.importing) {
      return;
    }
    this.slicing = true;
    this.status = '切片中…';
    try {
      const dir: string = this.filesDir();
      const settingsPath: string = `${dir}/default.json`;
      // The native renderer exports the modelling scene to scene.stl; fall back to the raw import when
      // that export has not happened yet.
      const scenePath: string = `${dir}/scene.stl`;
      const modelPath: string = fs.accessSync(scenePath) ? scenePath : `${dir}/cube.stl`;
      const outputPath: string = `${dir}/cube.gcode`;

      this.materialiseRawFile('profiles/default.json', settingsPath);
      const overrides: string[] = this.settings.map((item: SlicerSetting): string => item.toOverride());

      slice(settingsPath, [modelPath], outputPath, `${dir}/curaengine.log`, overrides)
        .then((code: number): void => {
          const size: number = fs.statSync(outputPath).size;
          const lines: number = fs.readTextSync(outputPath).split('\n').length;
          this.status = `切片成功：${size} 字节 / ${lines} 层`;
          hilog.info(DOMAIN, 'CuraSlice', 'SLICE_OK code=%{public}d size=%{public}d', code, size);
          this.refreshLog();
        })
        .catch((error: Error): void => {
          this.status = `切片失败：${error.message}`;
          hilog.error(DOMAIN, 'CuraSlice', 'SLICE_FAIL reason=%{public}s', error.message);
          this.refreshLog();
        })
        .finally((): void => {
          this.slicing = false;
        });
    } catch (error) {
      const err = error as BusinessError;
      this.status = `准备失败：${err.message}`;
      this.slicing = false;
    }
  }

  // Sidebar content shared by the desktop/tablet column and the phone bottom sheet.
  @Builder
  sidePanel() {
    Column() {
      Scroll() {
        Column({ space: 8 }) {
          if (this.isSmall) {
            // The top bar drops the mode toggle on phones, so it lives here instead.
            Button(this.moveMode ? '模式：移动（拖动模型）' : '模式：旋转（拖动视角）')
              .fontSize(12)
              .height(30)
              .width('100%')
              .backgroundColor(this.moveMode ? '#2f6fd0' : '#2a2d33')
              .onClick(() => {
                this.moveMode = !this.moveMode;
                this.persistViewMode();
              })
          }
          // USB printing is PC-only; phones and tablets do not show the printer panel at all.
          if (this.device.supportsPrinting) {
            PrinterPanel({ printer: this.printer, gcodePath: this.gcodePath })
            Divider().color('#2a2d33')
          }
          ModelPanel({
            scene: this.scene,
            selectedIndex: this.selectedIndex,
            version: this.sceneVersion,
            onSceneChanged: () => {
              this.commitScene();
            },
            onBoolean: (operation: string) => {
              this.runBoolean(operation);
            },
            onUndo: () => {
              this.undo();
            },
            onRedo: () => {
              this.redo();
            },
            onSaveProject: () => {
              this.saveProject();
            },
            onOpenProject: () => {
              this.openProject();
            },
            onExportStl: () => {
              this.exportStl();
            },
            onExport3mf: () => {
              this.export3mf();
            }
          })
          Divider().color('#2a2d33')
          SettingsPanel({ settings: this.settings })
        }
        .width('100%')
        .padding(12)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#161a1f')
  }

  build() {
    Column() {
      // Top bar: compact labels on phones so all actions still fit.
      Row({ space: this.isSmall ? 6 : 10 }) {
        Text(APP_NAME)
          .fontSize(this.isSmall ? 16 : 18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#ffffff')
        if (this.isSmall) {
          Blank()
        } else {
          Text(this.modelName)
            .fontSize(12)
            .fontColor('#8b9099')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Button(this.isSmall ? '导入' : '导入模型')
          .fontSize(this.isSmall ? 12 : 13)
          .height(this.isSmall ? 30 : 32)
          .backgroundColor('#2a2d33')
          .enabled(!this.importing && !this.slicing)
          .onClick(() => {
            this.importModel();
          })
        Button(this.slicing ? '切片中…' : '切片')
          .id('sliceButton')
          .fontSize(this.isSmall ? 12 : 13)
          .height(this.isSmall ? 30 : 32)
          .backgroundColor('#2f6fd0')
          .enabled(!this.slicing && !this.importing)
          .onClick(() => {
            this.runSlice();
          })
        if (this.isSmall) {
          Button(this.showSidePanel ? '收起' : '面板')
            .id('panelButton')
            .fontSize(12)
            .height(30)
            .backgroundColor(this.showSidePanel ? '#2f6fd0' : '#2a2d33')
            .onClick(() => {
              this.showSidePanel = !this.showSidePanel;
            })
        } else {
          Button(this.moveMode ? '模式：移动' : '模式：旋转')
            .id('moveModeButton')
            .fontSize(13)
            .height(32)
            .backgroundColor(this.moveMode ? '#2f6fd0' : '#2a2d33')
            .onClick(() => {
              this.moveMode = !this.moveMode;
              this.persistViewMode();
            })
        }
        Button('关于')
          .id('aboutButton')
          .fontSize(this.isSmall ? 12 : 13)
          .height(this.isSmall ? 30 : 32)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.aboutController.open();
          })
      }
      .width('100%')
      .height(this.isSmall ? 48 : 52)
      .padding({ left: this.isSmall ? 8 : 14, right: this.isSmall ? 8 : 14 })
      .backgroundColor('#1b1e23')

      // Main area: desktop/tablet keep a sidebar column, phones show a full-width preview with a
      // collapsible bottom sheet.
      if (this.isSmall) {
        Column() {
          Column() {
            XComponent({ id: 'curaPreview', type: XComponentType.SURFACE, libraryname: 'render' })
              .width('100%')
              .height('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#101317')

          if (this.showSidePanel) {
            Column() {
              this.sidePanel()
            }
            .width('100%')
            .height('42%')
            .border({ width: { top: 1 }, color: '#2a2d33' })
          }
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        Row() {
          Column() {
            this.sidePanel()
          }
          .width(this.isMedium ? 300 : 320)
          .height('100%')

          Column() {
            XComponent({ id: 'curaPreview', type: XComponentType.SURFACE, libraryname: 'render' })
              .width('100%')
              .height('100%')
          }
          .layoutWeight(1)
          .height('100%')
          .backgroundColor('#101317')
        }
        .width('100%')
        .layoutWeight(1)
      }

      // Bottom status bar
      Row({ space: 10 }) {
        Text(this.status)
          .fontSize(12)
          .fontColor('#c8ccd4')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!this.isSmall) {
          Text(this.engineInfo)
            .fontSize(10)
            .fontColor('#5d636d')
            .maxLines(1)
        }
        Text(`设备：${this.device.label()}`)
          .fontSize(10)
          .fontColor('#5d636d')
          .maxLines(1)
      }
      .width('100%')
      .height(34)
      .padding({ left: 14, right: 14 })
      .backgroundColor('#1b1e23')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101317')
  }
}
