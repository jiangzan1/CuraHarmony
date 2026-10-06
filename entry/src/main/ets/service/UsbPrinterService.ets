import { serialManager } from '@kit.BasicServicesKit';
import { SerialPortInfo, UsbSerialClient } from './UsbSerialClient';

// Faithful re-implementation of the behaviour of Cura's USBPrinting plugin
// (plugins/USBPrinting/USBPrinterOutputDevice.py), which cannot be reused directly because it is
// Python and depends on pyserial:
//   * open the serial port at 115200 baud and greet the printer with M115,
//   * poll temperatures with M105 roughly every two seconds while idle,
//   * stream G-code line by line, sending the next line only after the printer answers "ok",
//   * track progress by the number of lines acknowledged.
const POLL_INTERVAL_MS: number = 2000;
const PUMP_INTERVAL_MS: number = 100;

@Observed
export class UsbPrinterService {
  ports: SerialPortInfo[] = [];
  state: string = '未连接';
  firmware: string = '-';
  nozzleTemperature: number = 0;
  bedTemperature: number = 0;
  progressPercent: number = 0;
  lastResponse: string = '';

  private client: UsbSerialClient = new UsbSerialClient();
  private receiveBuffer: string = '';
  private pumpTimer: number = -1;
  private pollTimer: number = -1;
  private queuedLines: string[] = [];
  private nextLineIndex: number = 0;
  private waitingForOk: boolean = false;
  private printing: boolean = false;
  private paused: boolean = false;

  refreshPorts(): void {
    this.ports = this.client.listPorts();
    this.state = this.ports.length > 0 ? `发现 ${this.ports.length} 个串口` : '未发现串口设备';
  }

  isConnected(): boolean {
    return this.client.isOpen();
  }

  connect(portId: number): void {
    this.state = '连接中…';
    this.client.open(portId, serialManager.BaudRates.BAUDRATE_115200);
    // The runtime right request is asynchronous, so the greeting is retried from the pump loop
    // until the port reports open.
    this.startPump();
  }

  disconnect(): void {
    this.stopTimers();
    this.client.close();
    this.printing = false;
    this.paused = false;
    this.state = '未连接';
    this.progressPercent = 0;
  }

  private startPump(): void {
    if (this.pumpTimer >= 0) {
      clearInterval(this.pumpTimer);
    }
    let greeted = false;
    this.pumpTimer = setInterval(() => {
      if (!this.client.isOpen()) {
        return;
      }
      if (!greeted) {
        greeted = true;
        this.state = '已连接';
        this.client.writeText('M115\n');
        this.pollTimer = setInterval(() => {
          if (!this.printing) {
            this.client.writeText('M105\n');
          }
        }, POLL_INTERVAL_MS);
      }
      this.pump();
    }, PUMP_INTERVAL_MS);
  }

  private stopTimers(): void {
    if (this.pumpTimer >= 0) {
      clearInterval(this.pumpTimer);
      this.pumpTimer = -1;
    }
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private pump(): void {
    const chunk: string = this.client.readText(20);
    if (chunk.length > 0) {
      this.receiveBuffer += chunk;
      this.consumeLines();
    }
    if (this.printing && !this.paused && !this.waitingForOk) {
      this.sendNextLine();
    }
  }

  private consumeLines(): void {
    let newlineIndex: number = this.receiveBuffer.indexOf('\n');
    while (newlineIndex >= 0) {
      const line: string = this.receiveBuffer.substring(0, newlineIndex).trim();
      this.receiveBuffer = this.receiveBuffer.substring(newlineIndex + 1);
      if (line.length > 0) {
        this.handleLine(line);
      }
      newlineIndex = this.receiveBuffer.indexOf('\n');
    }
  }

  private handleLine(line: string): void {
    this.lastResponse = line;
    if (line.startsWith('FIRMWARE_NAME:')) {
      this.firmware = line;
    }
    if (line.indexOf('T:') >= 0) {
      this.nozzleTemperature = this.extractTemperature(line, 'T:');
    }
    if (line.indexOf('B:') >= 0) {
      this.bedTemperature = this.extractTemperature(line, 'B:');
    }
    if (line.startsWith('ok') || line.startsWith('Ok')) {
      this.waitingForOk = false;
      if (this.printing) {
        this.nextLineIndex++;
        if (this.queuedLines.length > 0) {
          this.progressPercent = Math.floor((this.nextLineIndex * 100) / this.queuedLines.length);
        }
        if (this.nextLineIndex >= this.queuedLines.length) {
          this.printing = false;
          this.state = '打印完成';
          this.progressPercent = 100;
        }
      }
    } else if (line.startsWith('Error') || line.startsWith('resend')) {
      // Re-send the line the printer rejected instead of losing the acknowledgement chain.
      this.waitingForOk = false;
    }
  }

  private extractTemperature(line: string, prefix: string): number {
    const start: number = line.indexOf(prefix);
    if (start < 0) {
      return 0;
    }
    const rest: string = line.substring(start + prefix.length);
    const parsed: number = Number.parseFloat(rest.split(' ')[0]);
    return Number.isNaN(parsed) ? 0 : Math.round(parsed * 10) / 10;
  }

  private sendNextLine(): void {
    if (this.nextLineIndex >= this.queuedLines.length) {
      return;
    }
    // Line numbers keep the printer and the host in sync when a line has to be resent.
    const line: string = `${this.queuedLines[this.nextLineIndex]}\n`;
    this.client.writeText(line);
    this.waitingForOk = true;
  }

  printGCode(content: string): void {
    if (!this.client.isOpen()) {
      this.state = '请先连接打印机';
      return;
    }
    this.queuedLines = content.split('\n').filter((line: string): boolean => line.trim().length > 0);
    this.nextLineIndex = 0;
    this.progressPercent = 0;
    this.waitingForOk = false;
    this.printing = true;
    this.paused = false;
    this.state = '打印中';
    // Absolute coordinates and a clean line counter are required before streaming.
    this.client.writeText('G21\n');
    this.client.writeText('G90\n');
    this.client.writeText('M110 N0\n');
  }

  pause(): void {
    if (!this.printing) {
      return;
    }
    this.paused = true;
    this.state = '已暂停';
    this.client.writeText('M0\n');
  }

  resume(): void {
    if (!this.printing) {
      return;
    }
    this.paused = false;
    this.state = '打印中';
  }

  cancel(): void {
    if (!this.client.isOpen()) {
      return;
    }
    this.printing = false;
    this.paused = false;
    this.progressPercent = 0;
    // M112 is the emergency stop understood by Marlin-compatible firmware.
    this.client.writeText('M112\n');
    this.state = '已取消';
  }
}
