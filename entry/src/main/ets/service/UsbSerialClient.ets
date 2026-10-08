import { serialManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

//! One enumerable USB serial port offered by the system.
export class SerialPortInfo {
  portId: number;
  deviceName: string;

  constructor(portId: number, deviceName: string) {
    this.portId = portId;
    this.deviceName = deviceName;
  }
}

// Thin wrapper over @ohos.usbManager.serial. Opening the port is exposed as a synchronous call that
// throws on failure, so the printer state machine can report the real error instead of silently
// staying "connecting".
export class UsbSerialClient {
  private portId: number = -1;
  private opened: boolean = false;
  private readFailures: number = 0;
  //! Last transport error, kept for display instead of throwing from timer callbacks.
  lastError: string = '';

  listPorts(): SerialPortInfo[] {
    const ports: serialManager.SerialPort[] = serialManager.getPortList();
    const result: SerialPortInfo[] = [];
    for (const port of ports) {
      result.push(new SerialPortInfo(port.portId, port.deviceName));
    }
    return result;
  }

  isOpen(): boolean {
    return this.opened;
  }

  hasRight(portId: number): boolean {
    return serialManager.hasSerialRight(portId);
  }

  requestRight(portId: number): Promise<boolean> {
    return serialManager.requestSerialRight(portId);
  }

  //! Opens the port and applies the baud rate. The caller must already hold the runtime right.
  openNow(portId: number, baudRate: serialManager.BaudRates): void {
    // A previous run of the application may have been killed while holding the port, in which case
    // the system still reports 31400004 ("device is using by other application"). Releasing the
    // handle first makes reconnection work without physically replugging the printer.
    try {
      serialManager.close(portId);
    } catch (error) {
      // Nothing is held by us: ignore and continue to open.
    }
    serialManager.open(portId);
    this.portId = portId;
    this.opened = true;
    // getAttribute() returns a read-only view, so a fresh value is written back. The native parser
    // rejects a partial object with 401 "Parse attribute failed", so every field is provided.
    const attribute: serialManager.SerialAttribute = {
      baudRate: baudRate,
      dataBits: serialManager.DataBits.DATABIT_8,
      parity: serialManager.Parity.PARITY_NONE,
      stopBits: serialManager.StopBits.STOPBIT_1
    };
    serialManager.setAttribute(portId, attribute);
    hilog.info(DOMAIN, 'UsbSerial', 'OPEN ok portId=%{public}d baud=%{public}d', portId, baudRate);
  }

  close(): void {
    if (!this.opened) {
      return;
    }
    try {
      serialManager.close(this.portId);
    } catch (error) {
      // Releasing an already-invalid handle must not abort the caller.
    }
    this.opened = false;
    this.portId = -1;
  }

  // The read/write helpers are called from timer callbacks, where an escaping exception would be an
  // uncaught ArkTS error and kill the application (observed as "Kill Reason: Js Error"). They
  // therefore swallow transport errors and surface them through `lastError` instead.
  writeText(text: string): number {
    if (!this.opened) {
      return 0;
    }
    try {
      const encoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(text);
      const written: number = serialManager.writeSync(this.portId, bytes, 1000);
      if (written <= 0) {
        this.lastError = `写入返回 ${written}`;
        hilog.error(DOMAIN, 'UsbSerial', 'WRITE_ZERO chars=%{public}d bytes=%{public}d', text.length, bytes.length);
      } else {
        // Clear stale failures so a successful write is not reported with an old error code.
        this.lastError = '';
      }
      return written;
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `写入失败：${err.code} ${err.message}`;
      hilog.error(DOMAIN, 'UsbSerial', 'WRITE_FAIL code=%{public}d msg=%{public}s', err.code, err.message);
      return 0;
    }
  }

  //! Reads whatever is currently buffered. Returns an empty string when nothing arrived in time.
  readText(timeoutMs: number): string {
    if (!this.opened) {
      return '';
    }
    try {
      const buffer = new Uint8Array(4096);
      const count: number = serialManager.readSync(this.portId, buffer, timeoutMs);
      if (count <= 0) {
        return '';
      }
      this.readFailures = 0;
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(buffer.subarray(0, count));
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `读取失败：${err.code}`;
      // Reading with an idle port raises an error every poll; log only the first few to stay useful.
      if (this.readFailures < 3) {
        hilog.error(DOMAIN, 'UsbSerial', 'READ_FAIL code=%{public}d msg=%{public}s', err.code, err.message);
      }
      this.readFailures++;
      return '';
    }
  }
}
