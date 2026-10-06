import { serialManager } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

//! One enumerable USB serial port offered by the system.
export class SerialPortInfo {
  portId: number;
  deviceName: string;

  constructor(portId: number, deviceName: string) {
    this.portId = portId;
    this.deviceName = deviceName;
  }
}

// Thin wrapper over @ohos.usbManager.serial. It performs the runtime right request that HarmonyOS
// requires before a third-party application may talk to a USB serial device, and keeps the byte
// level encoding away from the printer state machine.
export class UsbSerialClient {
  private portId: number = -1;
  private opened: boolean = false;

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

  currentPortId(): number {
    return this.portId;
  }

  open(portId: number, baudRate: serialManager.BaudRates): void {
    if (!serialManager.hasSerialRight(portId)) {
      // The runtime grant is required; without it open() fails with an access-right error.
      serialManager.requestSerialRight(portId).then((granted: boolean) => {
        if (granted) {
          this.openGrantedPort(portId, baudRate);
        }
      }).catch((error: Error) => {
        throw error;
      });
      return;
    }
    this.openGrantedPort(portId, baudRate);
  }

  private openGrantedPort(portId: number, baudRate: serialManager.BaudRates): void {
    serialManager.open(portId);
    // getAttribute() returns a read-only view, so a fresh value is written back.
    const attribute: serialManager.SerialAttribute = { baudRate: baudRate };
    serialManager.setAttribute(portId, attribute);
    this.portId = portId;
    this.opened = true;
  }

  close(): void {
    if (!this.opened) {
      return;
    }
    serialManager.close(this.portId);
    this.opened = false;
    this.portId = -1;
  }

  writeText(text: string): number {
    if (!this.opened) {
      return 0;
    }
    const encoder = new util.TextEncoder();
    const bytes: Uint8Array = encoder.encodeInto(text);
    return serialManager.writeSync(this.portId, bytes, 1000);
  }

  //! Reads whatever is currently buffered. Returns an empty string when nothing arrived in time.
  readText(timeoutMs: number): string {
    if (!this.opened) {
      return '';
    }
    const buffer = new Uint8Array(4096);
    const count: number = serialManager.readSync(this.portId, buffer, timeoutMs);
    if (count <= 0) {
      return '';
    }
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(buffer.subarray(0, count));
  }
}
