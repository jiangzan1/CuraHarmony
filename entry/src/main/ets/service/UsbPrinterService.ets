import { serialManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SerialPortInfo, UsbSerialClient } from './UsbSerialClient';

const DOMAIN = 0x0000;

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
  private waitingSince: number = 0;
  private printing: boolean = false;
  private paused: boolean = false;
  private receivedAny: boolean = false;

  refreshPorts(): void {
    this.ports = this.client.listPorts();
    this.state = this.ports.length > 0 ? `发现 ${this.ports.length} 个串口` : '未发现串口设备';
    const names: string = this.ports.map((port: SerialPortInfo): string => port.deviceName).join(', ');
    hilog.info(DOMAIN, 'UsbPrinter', 'PORTS count=%{public}d [%{public}s]', this.ports.length, names);
  }

  isConnected(): boolean {
    return this.client.isOpen();
  }

  connect(portId: number): void {
    this.state = '请求授权…';
    if (this.client.hasRight(portId)) {
      this.openPort(portId);
      return;
    }
    this.client.requestRight(portId).then((granted: boolean) => {
      if (granted) {
        this.openPort(portId);
      } else {
        this.state = 'USB 授权被拒绝';
      }
    }).catch((error: Error) => {
      this.state = `授权失败：${error.message}`;
    });
  }

  private openPort(portId: number): void {
    try {
      this.client.openNow(portId, serialManager.BaudRates.BAUDRATE_115200);
      this.state = '已连接';
      this.receivedAny = false;
      // Log the handshake result: if the write reports 0 the port is not really writable, and if it
      // succeeds but the printer never answers, the problem is on the wiring/baud/protocol side.
      const sent: number = this.client.writeText('M115\n');
      hilog.info(DOMAIN, 'UsbPrinter', 'M115 sent=%{public}d err=%{public}s', sent, this.client.lastError);
      this.startPump();
    } catch (error) {
      const err = error as BusinessError;
      this.state = `连接失败：${err.code} ${err.message}`;
      hilog.error(DOMAIN, 'UsbPrinter', 'CONNECT_FAIL code=%{public}d msg=%{public}s', err.code, err.message);
    }
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
    this.pumpTimer = setInterval(() => {
      // An exception escaping a timer callback is an uncaught ArkTS error that terminates the
      // application, so the whole body is guarded.
      try {
        if (this.client.isOpen()) {
          this.pump();
        }
      } catch (error) {
        const err = error as BusinessError;
        this.state = `串口异常：${err.code}`;
      }
    }, PUMP_INTERVAL_MS);

    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
    }
    this.pollTimer = setInterval(() => {
      try {
        if (this.client.isOpen() && !this.printing) {
          this.client.writeText('M105\n');
        }
      } catch (error) {
        const err = error as BusinessError;
        this.state = `温度轮询异常：${err.code}`;
      }
    }, POLL_INTERVAL_MS);
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
      if (!this.receivedAny) {
        this.receivedAny = true;
        hilog.info(DOMAIN, 'UsbPrinter', 'RX first len=%{public}d text=%{public}s', chunk.length, chunk);
      }
      this.receiveBuffer += chunk;
      this.consumeLines();
    }
    if (this.printing && !this.paused && !this.waitingForOk) {
      this.sendNextLine();
    }
    // A printer that never answers would leave the UI stuck on "打印中" forever; abort with a reason.
    // The window is generous because a homing move (G28) can take many seconds before Marlin replies.
    if (this.printing && this.waitingForOk && this.waitingSince > 0 && Date.now() - this.waitingSince > 30000) {
      this.waitingForOk = false;
      this.printing = false;
      this.state = '打印机无应答（超时），请检查串口/波特率后重连';
      hilog.error(DOMAIN, 'UsbPrinter', 'ACK_TIMEOUT line=%{public}d resp=%{public}s', this.nextLineIndex, this.lastResponse);
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
    // Any traffic proves the printer is alive. Heating commands (M109/M190) answer with repeated
    // "echo:busy: processing" for minutes and only send "ok" once the target temperature is reached,
    // so the stall timer must be refreshed on every line instead of aborting during the heat-up.
    this.waitingSince = Date.now();
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
        if (this.nextLineIndex % 200 === 0) {
          hilog.info(DOMAIN, 'UsbPrinter', 'PRINT_PROGRESS line=%{public}d pct=%{public}d', this.nextLineIndex, this.progressPercent);
        }
        if (this.nextLineIndex >= this.queuedLines.length) {
          this.printing = false;
          this.state = '打印完成';
          this.progressPercent = 100;
          hilog.info(DOMAIN, 'UsbPrinter', 'PRINT_DONE lines=%{public}d', this.nextLineIndex);
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
    const written: number = this.client.writeText(line);
    if (written <= 0) {
      // Without a successful write the printer never answers "ok"; stop instead of hanging forever.
      this.printing = false;
      this.state = `发送失败：${this.client.lastError}`;
      hilog.error(DOMAIN, 'UsbPrinter', 'WRITE_FAIL line=%{public}d reason=%{public}s', this.nextLineIndex, this.client.lastError);
      return;
    }
    this.waitingForOk = true;
    this.waitingSince = Date.now();
  }

  printGCode(content: string): void {
    if (!this.client.isOpen()) {
      this.state = '请先连接打印机';
      hilog.warn(DOMAIN, 'UsbPrinter', 'PRINT_SKIP not connected');
      return;
    }
    // Drop empty lines and comment-only lines (";FLAVOR:Marlin", ";TIME:..."): several Marlin builds
    // ignore pure comments and never answer "ok" for them, which would stall the ok-based streaming on
    // the very first line. Lines that carry a trailing comment ("G1 X0 Y0 ; move") are kept.
    const body: string[] = content.split('\n').filter((line: string): boolean => {
      const trimmed: string = line.trim();
      return trimmed.length > 0 && !trimmed.startsWith(';');
    });
    if (body.length === 0) {
      this.state = 'G-code 为空，无法打印';
      hilog.warn(DOMAIN, 'UsbPrinter', 'PRINT_SKIP empty gcode');
      return;
    }
    // The setup commands are streamed inside the same ack chain. Writing them outside the queue made
    // their "ok" answers consume the first real line's acknowledgement and desynced the print.
    this.queuedLines = ['G21', 'G90', 'M110 N0'].concat(body);
    this.nextLineIndex = 0;
    this.progressPercent = 0;
    this.waitingForOk = false;
    this.printing = true;
    this.paused = false;
    this.state = '打印中';
    hilog.info(DOMAIN, 'UsbPrinter', 'PRINT_START lines=%{public}d', this.queuedLines.length);
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
