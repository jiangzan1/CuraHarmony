import { fileIo as fs } from '@kit.CoreFileKit';

// Persists the "privacy policy accepted" flag. A sandbox marker file is used instead of
// Preferences so the app keeps a single, dependency-free persistence mechanism.
export class ConsentStore {
  private static readonly MARKER: string = 'privacy_agreed';

  static isPrivacyAgreed(filesDir: string): boolean {
    try {
      return fs.accessSync(`${filesDir}/${ConsentStore.MARKER}`);
    } catch (error) {
      return false;
    }
  }

  static agreePrivacy(filesDir: string): void {
    try {
      const file = fs.openSync(
        `${filesDir}/${ConsentStore.MARKER}`,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC
      );
      fs.closeSync(file);
    } catch (error) {
      // Best-effort: if the marker cannot be written the prompt is shown again next launch.
    }
  }
}
