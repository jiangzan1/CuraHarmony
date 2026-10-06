import { getEngineInfo, slice } from 'libcuraslicer.so';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SlicerSetting, createDefaultSettings } from '../model/SlicerSetting';
import { SettingsPanel } from '../view/SettingsPanel';

const DOMAIN = 0x0000;

@Entry
@Component
struct Index {
  @State settings: SlicerSetting[] = createDefaultSettings();
  @State status: string = '就绪';
  @State modelName: string = 'cube.stl（内置示例）';
  @State engineInfo: string = '';
  @State logTail: string = '';

  aboutToAppear(): void {
    this.engineInfo = getEngineInfo();
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
  }

  private filesDir(): string {
    return getContext(this).filesDir;
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
    try {
      const documentPicker = new picker.DocumentViewPicker(getContext(this));
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.stl'];
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const source = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      const target = fs.openSync(`${this.filesDir()}/cube.stl`, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(source.fd, target.fd);
      } finally {
        fs.closeSync(source);
        fs.closeSync(target);
      }
      const name: string = uris[0].split('/').pop() ?? 'model.stl';
      this.modelName = name;
      this.status = `已导入 ${name}`;
    } catch (error) {
      const err = error as BusinessError;
      this.status = `导入失败：${err.message}`;
      hilog.error(DOMAIN, 'CuraSlice', 'IMPORT_FAIL reason=%{public}s', err.message);
    }
  }

  private runSlice(): void {
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
        });
    } catch (error) {
      const err = error as BusinessError;
      this.status = `准备失败：${err.message}`;
    }
  }

  build() {
    Column() {
      // Top bar
      Row({ space: 10 }) {
        Text('CuraHarmony')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#ffffff')
        Text(this.modelName)
          .fontSize(12)
          .fontColor('#8b9099')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('导入模型')
          .fontSize(13)
          .height(32)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.importModel();
          })
        Button('切片')
          .id('sliceButton')
          .fontSize(13)
          .height(32)
          .backgroundColor('#2f6fd0')
          .onClick(() => {
            this.runSlice();
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 14, right: 14 })
      .backgroundColor('#1b1e23')

      // Main area: settings sidebar + 3D preview
      Row() {
        Column() {
          SettingsPanel({ settings: this.settings })
        }
        .width(300)
        .height('100%')
        .backgroundColor('#161a1f')

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

      // Bottom status bar
      Row({ space: 10 }) {
        Text(this.status)
          .fontSize(12)
          .fontColor('#c8ccd4')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.engineInfo)
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
