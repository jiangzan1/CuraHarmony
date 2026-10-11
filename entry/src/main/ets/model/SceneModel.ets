import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

// One object of the modelling scene. Primitives (cube/cylinder/sphere/cone) are generated natively,
// "imported" is the mesh the user loaded and "mesh" is a boolean result file. The scene is the source
// of truth on the ArkTS side and is handed to the native renderer through scene.json.
@Observed
export class SceneObject {
  kind: string;   // cube | cylinder | sphere | cone | imported | mesh
  label: string;
  file: string;   // sandbox file name for mesh/imported objects
  size: number;   // mm (primitives)
  px: number;
  py: number;
  pz: number;
  rx: number;     // degrees
  ry: number;
  rz: number;
  scale: number;  // uniform

  constructor(kind: string, label: string, size: number) {
    this.kind = kind;
    this.label = label;
    this.file = '';
    this.size = size;
    this.px = 0;
    this.py = 0;
    this.pz = 0;
    this.rx = 0;
    this.ry = 0;
    this.rz = 0;
    this.scale = 1;
  }

  // Adjusts one axis of the position (0=x, 1=y, 2=z); ArkTS has no dynamic property access.
  adjustPosition(axis: number, delta: number): void {
    if (axis === 0) {
      this.px = this.px + delta;
    } else if (axis === 1) {
      this.py = this.py + delta;
    } else {
      this.pz = Math.max(0, this.pz + delta);
    }
  }

  adjustRotation(axis: number, delta: number): void {
    if (axis === 0) {
      this.rx = this.wrapDegrees(this.rx + delta);
    } else if (axis === 1) {
      this.ry = this.wrapDegrees(this.ry + delta);
    } else {
      this.rz = this.wrapDegrees(this.rz + delta);
    }
  }

  adjustSize(delta: number): void {
    this.size = Math.max(1, Math.round((this.size + delta) * 10) / 10);
  }

  setSize(value: number): void {
    if (!Number.isNaN(value) && value >= 1) {
      this.size = Math.round(value * 10) / 10;
    }
  }

  adjustScale(delta: number): void {
    this.scale = Math.max(0.1, Math.round((this.scale + delta) * 100) / 100);
  }

  //! Sends the object back to the centre of the plate and onto it.
  centerOnPlate(): void {
    this.px = 0;
    this.py = 0;
    this.pz = 0;
  }

  private wrapDegrees(value: number): number {
    let next: number = value;
    if (next > 180) {
      next = next - 360;
    } else if (next < -180) {
      next = next + 360;
    }
    return next;
  }

  clone(): SceneObject {
    const copy = new SceneObject(this.kind, this.label, this.size);
    copy.file = this.file;
    copy.px = this.px;
    copy.py = this.py;
    copy.pz = this.pz;
    copy.rx = this.rx;
    copy.ry = this.ry;
    copy.rz = this.rz;
    copy.scale = this.scale;
    return copy;
  }

  // Serialised by hand so the native rapidjson parser sees exactly the expected shape.
  toJson(): string {
    return `{"kind":"${this.kind}","size":${this.size},"file":"${this.file}",`
      + `"position":[${this.px},${this.py},${this.pz}],`
      + `"rotation":[${this.rx},${this.ry},${this.rz}],`
      + `"scale":[${this.scale},${this.scale},${this.scale}]}`;
  }
}

export class SceneStore {
  // Writes scene.json; the native renderer polls its mtime, rebuilds the scene and re-exports STL.
  static persist(filesDir: string, scene: SceneObject[]): void {
    try {
      const body: string = '{"objects":[' + scene.map((item: SceneObject): string => item.toJson()).join(',') + ']}';
      const file = fs.openSync(`${filesDir}/scene.json`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, body);
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'SceneStore', 'SCENE_WRITE_FAIL reason=%{public}s', err.message);
    }
  }
}
