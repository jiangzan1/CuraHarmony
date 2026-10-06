import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SerialPortInfo } from '../service/UsbSerialClient';
import { UsbPrinterService } from '../service/UsbPrinterService';

// Cura's "Monitor" tab in miniature: serial port selection, connection state, live temperatures,
// print progress and the pause/cancel controls.
@Component
export struct PrinterPanel {
  @ObjectLink printer: UsbPrinterService;
  @Prop gcodePath: string;

  private sendGCodeToPrinter(): void {
    try {
      if (!fs.accessSync(this.gcodePath)) {
        this.printer.state = '请先切片生成 G-code';
        return;
      }
      const content: string = fs.readTextSync(this.gcodePath);
      this.printer.printGCode(content);
    } catch (error) {
      const err = error as BusinessError;
      this.printer.state = `读取 G-code 失败：${err.message}`;
    }
  }

  build() {
    Column({ space: 6 }) {
      Row() {
        Text('打印机')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#ffffff')
          .layoutWeight(1)
        Text(this.printer.state)
          .fontSize(12)
          .fontColor('#6fb1ff')
      }
      .width('100%')

      Text(this.printer.firmware)
        .fontSize(10)
        .fontColor('#8b9099')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(`喷嘴 ${this.printer.nozzleTemperature}℃  热床 ${this.printer.bedTemperature}℃`)
        .fontSize(12)
        .fontColor('#c8ccd4')
        .width('100%')

      Progress({ value: this.printer.progressPercent, total: 100, type: ProgressType.Linear })
        .width('100%')

      Row({ space: 6 }) {
        Button('刷新端口')
          .fontSize(12)
          .height(30)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.printer.refreshPorts();
          })
        Button('断开')
          .fontSize(12)
          .height(30)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.printer.disconnect();
          })
      }

      ForEach(this.printer.ports, (port: SerialPortInfo) => {
        Row({ space: 6 }) {
          Text(port.deviceName)
            .fontSize(11)
            .fontColor('#c8ccd4')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('连接')
            .fontSize(12)
            .height(28)
            .backgroundColor('#2f6fd0')
            .onClick(() => {
              this.printer.connect(port.portId);
            })
        }
        .width('100%')
      }, (port: SerialPortInfo): string => `${port.portId}`)

      Row({ space: 6 }) {
        Button('打印')
          .fontSize(12)
          .height(30)
          .backgroundColor('#2f6fd0')
          .onClick(() => {
            this.sendGCodeToPrinter();
          })
        Button('暂停')
          .fontSize(12)
          .height(30)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.printer.pause();
          })
        Button('取消')
          .fontSize(12)
          .height(30)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.printer.cancel();
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: 12 })
  }
}
