import { getEngineInfo, ping } from 'libcuraslicer.so';

@Entry
@Component
struct Index {
  @State message: string = 'CuraHarmony';
  @State pingResult: string = '';
  @State nativeInfo: string = '';

  aboutToAppear(): void {
    this.pingResult = ping();
    this.nativeInfo = getEngineInfo();
  }

  build() {
    Column({ space: 12 }) {
      Text(this.message)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text(`ping: ${this.pingResult}`)
        .fontSize(16)
      Text(this.nativeInfo)
        .fontSize(14)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }
}
