import { getEngineInfo, slice } from 'libcuraslicer.so';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { mediaquery } from '@kit.ArkUI';
import { SlicerSetting, createDefaultSettings } from '../model/SlicerSetting';
import { APP_NAME, PRIVACY_SUMMARY } from '../model/AppInfo';
import { SettingsPanel } from '../view/SettingsPanel';
import { PrinterPanel } from '../view/PrinterPanel';
import { AboutDialog } from '../view/AboutDialog';
import { UsbPrinterService } from '../service/UsbPrinterService';
import { ConsentStore } from '../service/ConsentStore';
import { Mesh3mf } from '../service/Mesh3mf';
import { DeviceProfile } from '../model/DeviceProfile';

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

  private smallQuery: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(width<600vp)');
  private mediumQuery: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(600vp<=width<840vp)');

  //! What this device is and which features it can use (see DeviceProfile).
  private device: DeviceProfile = new DeviceProfile();

  private consentChecked: boolean = false;
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

  // Store compliance: usage requires accepting the privacy policy on first launch.
  onPageShow(): void {
    if (this.consentChecked) {
      return;
    }
    this.consentChecked = true;
    if (!ConsentStore.isPrivacyAgreed(this.filesDir())) {
      this.showPrivacyConsent();
    }
  }

  private showPrivacyConsent(): void {
    AlertDialog.show({
      title: '隐私政策',
      message: PRIVACY_SUMMARY,
      autoCancel: false,
      primaryButton: {
        value: '不同意并退出',
        action: (): void => {
          this.exitApp();
        }
      },
      secondaryButton: {
        value: '同意',
        action: (): void => {
          ConsentStore.agreePrivacy(this.filesDir());
        }
      }
    });
  }

  private exitApp(): void {
    try {
      getContext(this).getApplicationContext().killAllProcesses().catch((error: BusinessError) => {
        hilog.error(DOMAIN, 'CuraSlice', 'EXIT_FAIL reason=%{public}s', error.message);
      });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'CuraSlice', 'EXIT_FAIL reason=%{public}s', err.message);
    }
  }

  private filesDir(): string {
    return getContext(this).filesDir;
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
      options.fileSuffixFilters = ['.stl', '.3mf'];
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const name: string = uris[0].split('/').pop() ?? 'model.stl';
      const dir: string = this.filesDir();
      const modelPath: string = `${dir}/cube.stl`;

      if (name.toLowerCase().endsWith('.3mf')) {
        // 3MF is a zip archive; flatten it to a binary STL that the preview and CuraEngine accept.
        this.status = '正在解析 3MF…';
        const zipPath: string = `${dir}/import_tmp.3mf`;
        this.copyPickedFile(uris[0], zipPath);
        const triangles: number = await Mesh3mf.convertToStl(zipPath, dir, modelPath);
        this.modelName = name;
        this.status = `已导入 ${name}（${triangles} 个三角面）`;
      } else {
        this.copyPickedFile(uris[0], modelPath);
        this.modelName = name;
        this.status = `已导入 ${name}`;
      }
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
      const modelPath: string = `${dir}/cube.stl`;
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
