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
    // The native preview loads cube.stl from the sandbox, so make sure it is there before the
    // XComponent surface is created.
    try {
      this.materialiseRawFile('models/cube.stl', `${getContext(this).filesDir}/cube.stl`);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'CuraSlice', 'MODEL_PREP_FAIL reason=%{public}s', err.message);
    }
    this.refreshLog();
  }

  // CuraEngine needs real file paths, so the bundled profile and test model are materialised into
  // the application sandbox before slicing, and the resulting G-code is read back from there.
  // The 3D preview loads the same cube.stl from that sandbox path on the native side.
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

  private refreshLog(): void {
    const dir: string = getContext(this).filesDir;
    this.lastLog = `[render]\n${this.readTail(`${dir}/render.log`, 6)}\n[engine]\n${this.readTail(`${dir}/curaengine.log`, 4)}`;
  }

  private readTail(path: string, count: number): string {
    try {
      if (!fs.accessSync(path)) {
        return '(无)';
      }
      const lines: string[] = fs.readTextSync(path).split('\n').filter((line: string): boolean => line.length > 0);
      return lines.slice(-count).join('\n');
    } catch (error) {
      const err = error as BusinessError;
      return `读取失败：${err.message}`;
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
          this.sliceResult = `成功 (code ${code})：${size} 字节 / ${lines.length} 行`;
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
    }
  }

  build() {
    Column({ space: 8 }) {
      // 3D preview: rendered by librender.so (EGL + OpenGL ES 3.0).
      XComponent({ id: 'curaPreview', type: XComponentType.SURFACE, libraryname: 'render' })
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#16181c')

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
        .fontColor('#888888')
      Text(this.lastLog)
        .fontSize(10)
        .fontColor('#666666')
        .maxLines(5)
    }
    .width('100%')
    .height('100%')
    .padding(12)
  }
}
