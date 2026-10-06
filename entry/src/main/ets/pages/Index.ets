import { getEngineInfo, ping, slice } from 'libcuraslicer.so';

@Entry
@Component
struct Index {
  @State pingResult: string = '';
  @State engineInfo: string = '';
  @State sliceCheck: string = '未运行';

  aboutToAppear(): void {
    this.pingResult = ping();
    this.engineInfo = getEngineInfo();
  }

  runNativeSelfCheck(): void {
    this.sliceCheck = '运行中…';
    slice('/data/storage/el2/base/nonexistent.json', [], '/data/storage/el2/base/nonexistent.gcode')
      .then((code: number): void => {
        this.sliceCheck = `slice 返回 ${code}`;
      })
      .catch((error: Error): void => {
        this.sliceCheck = `slice 已拒绝：${error.message}`;
      });
  }

  build() {
    Column({ space: 12 }) {
      Text('CuraHarmony')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
      Text('M1：原生 CuraEngine 桥接自检')
        .fontSize(14)
        .fontColor('#888888')

      Text(`ping: ${this.pingResult}`)
        .fontSize(16)
      Text(this.engineInfo)
        .fontSize(13)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)

      Button('运行原生自检')
        .onClick(() => {
          this.runNativeSelfCheck();
        })
      Text(`切片调用：${this.sliceCheck}`)
        .fontSize(13)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }
}
