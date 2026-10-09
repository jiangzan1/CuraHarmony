import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    this.configureWindow(windowStage);
  }

  // Window policy differs per device: a 2in1 (PC) runs immersive and maximised like the desktop Cura
  // window, while phone/tablet keep the system bars so the content is not drawn underneath them.
  private configureWindow(windowStage: window.WindowStage): void {
    const isPc: boolean = deviceInfo.deviceType === '2in1';
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      if (isPc) {
        // Cura is a full-screen desktop-class application, so the window is launched immersive and
        // maximised instead of floating. Each call is independent: failing one must not abort the others.
        mainWindow.setWindowLayoutFullScreen(true).catch((error: BusinessError) => {
          hilog.warn(DOMAIN, 'testTag', 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(error));
        });
        mainWindow.setWindowSystemBarEnable([]).catch((error: BusinessError) => {
          hilog.warn(DOMAIN, 'testTag', 'setWindowSystemBarEnable failed: %{public}s', JSON.stringify(error));
        });
        mainWindow.maximize().catch((error: BusinessError) => {
          hilog.warn(DOMAIN, 'testTag', 'maximize failed: %{public}s', JSON.stringify(error));
        });
      } else {
        mainWindow.setWindowLayoutFullScreen(false).catch((error: BusinessError) => {
          hilog.warn(DOMAIN, 'testTag', 'setWindowLayoutFullScreen(false) failed: %{public}s', JSON.stringify(error));
        });
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'testTag', 'configureWindow failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
