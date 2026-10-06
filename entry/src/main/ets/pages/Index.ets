import { getEngineInfo, ping, slice } from 'libcuraslicer.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

@Entry
@Component
struct Index {
  @State pingResult: string = '';
  @State engineInfo: string = '';
  @State sliceResult: string = '未运行';
  @State lastLog: string = '';

  aboutToAppear(): void {
    this.pingResult = ping();
    this.engineInfo = getEngineInfo();
    this.refreshLog();
  }

  // CuraEngine needs real file paths, so the bundled profile and test model are materialised into
  // the application sandbox before slicing, and the resulting G-code is read back from there.
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

  private logPath(): string {
    return `${getContext(this).filesDir}/curaengine.log`;
  }

  // CuraEngine's own log is kept in the sandbox. Showing its tail here means a failed or crashing
  // slice can still be diagnosed after relaunching the application.
  private refreshLog(): void {
    const path: string = this.logPath();
    try {
      if (!fs.accessSync(path)) {
        this.lastLog = '(无日志)';
        return;
      }
      const lines: string[] = fs.readTextSync(path).split('\n');
      const tail: string[] = lines.filter((line: string): boolean => line.length > 0).slice(-8);
      this.lastLog = tail.join('\n');
    } catch (error) {
      const err = error as BusinessError;
      this.lastLog = `日志读取失败：${err.message}`;
    }
  }

  private runSlice(): void {
    this.sliceResult = '准备中…';
    try {
      const context = getContext(this);
      const dir: string = context.filesDir;
      const settingsPath: string = `${dir}/default.json`;
      const modelPath: string = `${dir}/cube.stl`;
      const outputPath: string = `${dir}/cube.gcode`;

      this.materialiseRawFile('profiles/default.json', settingsPath);
      this.materialiseRawFile('models/cube.stl', modelPath);

      this.sliceResult = '切片中…';
      slice(settingsPath, [modelPath], outputPath, this.logPath())
        .then((code: number): void => {
          const size: number = fs.statSync(outputPath).size;
          const text: string = fs.readTextSync(outputPath);
          const lines: string[] = text.split('\n');
          this.sliceResult = `成功 (code ${code})：${size} 字节 / ${lines.length} 行\n${lines[0]}`;
          hilog.info(DOMAIN, 'CuraSlice', 'SLICE_OK code=%{public}d size=%{public}d', code, size);
          this.refreshLog();
        })
        .catch((error: Error): void => {
          this.sliceResult = `失败：${error.message}`;
          hilog.error(DOMAIN, 'CuraSlice', 'SLICE_FAIL reason=%{public}s', error.message);
          this.refreshLog();
        });
    } catch (error) {
      const err = error as BusinessError;
      this.sliceResult = `准备失败：${err.message}`;
      hilog.error(DOMAIN, 'CuraSlice', 'SLICE_PREP_FAIL reason=%{public}s', err.message);
    }
  }

  build() {
    Column({ space: 10 }) {
      Text('CuraHarmony')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text('M2：原生 CuraEngine 端到端切片')
        .fontSize(13)
        .fontColor('#888888')
      Text(this.engineInfo)
        .fontSize(12)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)

      Row({ space: 10 }) {
        Button('切片测试立方体')
          .id('sliceButton')
          .onClick(() => {
            this.runSlice();
          })
        Button('刷新日志')
          .onClick(() => {
            this.refreshLog();
          })
      }

      Text(this.sliceResult)
        .fontSize(13)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)

      Text('引擎日志尾部')
        .fontSize(12)
        .fontColor('#888888')
      Scroll() {
        Text(this.lastLog)
          .fontSize(11)
          .fontColor('#999999')
          .textAlign(TextAlign.Start)
      }
      .width('90%')
      .height(200)
      .backgroundColor('#111111')
      .padding(8)
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .justifyContent(FlexAlign.Center)
  }
}
