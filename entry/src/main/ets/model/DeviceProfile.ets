import { deviceInfo } from '@kit.BasicServicesKit';

// Detects what the app is running on and which features that device can actually use.
//
// Two granularities are combined on purpose:
//   * deviceInfo.deviceType gives the coarse class (phone / tablet / 2in1 / ...) for layout and UX;
//   * canIUse(SystemCapability...) tells whether a capability really exists, which is more reliable
//     than guessing from the class (a phone without OTG cannot host a USB serial printer, but the
//     system reports the capability itself).
export class DeviceProfile {
    //! '2in1' | 'tablet' | 'phone' | 'wearable' | 'car' | 'tv' | 'default' | ...
    readonly kind: string;
    //! USB serial port access (3D printer connection).
    readonly supportsSerial: boolean;
    //! Desktop window affordances (maximise / immersive system bars).
    readonly supportsDesktopWindow: boolean;
    //! USB printing is a PC-only feature: phones/tablets hide the printer panel entirely.
    readonly supportsPrinting: boolean;

    constructor() {
        this.kind = deviceInfo.deviceType;
        this.supportsSerial = canIUse('SystemCapability.USB.USBManager.Serial');
        this.supportsDesktopWindow = this.kind === '2in1';
        this.supportsPrinting = this.kind === '2in1';
    }

    isPc(): boolean {
        return this.kind === '2in1';
    }

    isTablet(): boolean {
        return this.kind === 'tablet';
    }

    isPhone(): boolean {
        return this.kind === 'phone';
    }

    //! Human readable name for the status bar.
    label(): string {
        if (this.isPc()) {
            return 'PC';
        }
        if (this.isTablet()) {
            return '平板';
        }
        if (this.isPhone()) {
            return '手机';
        }
        return this.kind;
    }
}
