import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SceneObject } from '../model/SceneModel';

const DOMAIN = 0x0000;

const HEADER = 'SFSCENE1';

// Project files (.sfproj) are plain text lines: a header followed by one line per object. A text format
// avoids JSON type gymnastics in ArkTS and stays human readable; scene.json (for the native renderer)
// is written separately by SceneStore.
export class ProjectStore {
  static serialize(scene: SceneObject[]): string {
    const lines: string[] = [HEADER];
    for (const item of scene) {
      lines.push(`${item.kind}|${item.label}|${item.file}|${item.size}|${item.px}|${item.py}|${item.pz}`
        + `|${item.rx}|${item.ry}|${item.rz}|${item.scale}`);
    }
    return lines.join('\n');
  }

  static parse(text: string): SceneObject[] {
    const result: SceneObject[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0 || line === HEADER) {
        continue;
      }
      const parts: string[] = line.split('|');
      if (parts.length !== 11) {
        continue;
      }
      const object = new SceneObject(parts[0], parts[1], Number.parseFloat(parts[3]));
      object.file = parts[2];
      object.px = Number.parseFloat(parts[4]);
      object.py = Number.parseFloat(parts[5]);
      object.pz = Number.parseFloat(parts[6]);
      object.rx = Number.parseFloat(parts[7]);
      object.ry = Number.parseFloat(parts[8]);
      object.rz = Number.parseFloat(parts[9]);
      object.scale = Number.parseFloat(parts[10]);
      result.push(object);
    }
    return result;
  }

  //! Asks for a destination and writes `text`; returns the chosen URI or '' when cancelled.
  static async saveText(context: common.Context, suggestedName: string, text: string): Promise<string> {
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [suggestedName];
      const saver = new picker.DocumentViewPicker(context);
      const uris: string[] = await saver.save(options);
      if (uris.length === 0) {
        return '';
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
      return uris[0];
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'ProjectStore', 'SAVE_TEXT_FAIL reason=%{public}s', err.message);
      return '';
    }
  }

  //! Copies an existing sandbox file to a user-chosen destination.
  static async saveFile(context: common.Context, suggestedName: string, sourcePath: string): Promise<string> {
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [suggestedName];
      const saver = new picker.DocumentViewPicker(context);
      const uris: string[] = await saver.save(options);
      if (uris.length === 0) {
        return '';
      }
      const source = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY);
      try {
        const target = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.copyFileSync(source.fd, target.fd);
        } finally {
          fs.closeSync(target);
        }
      } finally {
        fs.closeSync(source);
      }
      return uris[0];
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'ProjectStore', 'SAVE_FILE_FAIL reason=%{public}s', err.message);
      return '';
    }
  }

  //! Lets the user pick a project file and returns its sandbox-local copy path ('' when cancelled).
  static async pickToSandbox(context: common.Context, filesDir: string): Promise<string> {
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return '';
      }
      const target: string = `${filesDir}/project_open.sfproj`;
      const source = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      try {
        const file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.copyFileSync(source.fd, file.fd);
        } finally {
          fs.closeSync(file);
        }
      } finally {
        fs.closeSync(source);
      }
      return target;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'ProjectStore', 'PICK_FAIL reason=%{public}s', err.message);
      return '';
    }
  }

  static readText(path: string): string {
    try {
      return fs.readTextSync(path);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'ProjectStore', 'READ_FAIL reason=%{public}s', err.message);
      return '';
    }
  }

  //! Converts the exported binary STL into a 3MF package and returns its sandbox path ('' on failure).
  static async export3mf(filesDir: string, stlPath: string): Promise<string> {
    try {
      const work: string = `${filesDir}/3mf_export`;
      ProjectStore.removeTree(work);
      fs.mkdirSync(`${work}/3D`);
      fs.mkdirSync(`${work}/_rels`);

      const bytes: ArrayBuffer = ProjectStore.readBinary(stlPath);
      if (bytes.byteLength < 84) {
        return '';
      }
      const view = new DataView(bytes);
      const triangles = view.getUint32(80, true);

      let vertices = '';
      let faces = '';
      let vertexIndex = 0;
      for (let t = 0; t < triangles; t++) {
        const base = 84 + t * 50;
        const indexes: number[] = [];
        for (let v = 0; v < 3; v++) {
          const x = view.getFloat32(base + 12 + v * 12, true);
          const y = view.getFloat32(base + 16 + v * 12, true);
          const z = view.getFloat32(base + 20 + v * 12, true);
          vertices += `<vertex x="${x}" y="${y}" z="${z}"/>`;
          indexes.push(vertexIndex);
          vertexIndex = vertexIndex + 1;
        }
        faces += `<triangle v1="${indexes[0]}" v2="${indexes[1]}" v3="${indexes[2]}"/>`;
      }

      const model = '<?xml version="1.0" encoding="UTF-8"?>\n'
        + '<model unit="millimeter" xml:lang="en-US" '
        + 'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\n'
        + '<resources>\n<object id="1" type="model">\n<mesh>\n'
        + `<vertices>${vertices}</vertices>\n<triangles>${faces}</triangles>\n`
        + '</mesh>\n</object>\n</resources>\n<build>\n<item objectid="1"/>\n</build>\n</model>\n';

      const contentTypes = '<?xml version="1.0" encoding="UTF-8"?>\n'
        + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n'
        + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n'
        + '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>\n'
        + '</Types>\n';
      const rels = '<?xml version="1.0" encoding="UTF-8"?>\n'
        + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
        + '<Relationship Target="/3D/3dmodel.model" Id="rel0" '
        + 'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\n'
        + '</Relationships>\n';

      ProjectStore.writeText(`${work}/[Content_Types].xml`, contentTypes);
      ProjectStore.writeText(`${work}/_rels/.rels`, rels);
      ProjectStore.writeText(`${work}/3D/3dmodel.model`, model);

      const zipPath: string = `${filesDir}/export.3mf`;
      try {
        fs.unlinkSync(zipPath);
      } catch (error) {
        // No previous export.
      }
      const zipOptions: zlib.Options = {};
      await zlib.compressFile(work, zipPath, zipOptions);
      return zipPath;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, 'ProjectStore', 'EXPORT_3MF_FAIL reason=%{public}s', err.message);
      return '';
    }
  }

  private static writeText(path: string, text: string): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  private static readBinary(path: string): ArrayBuffer {
    const size: number = fs.statSync(path).size;
    const buffer = new ArrayBuffer(size);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buffer, { offset: 0, length: size });
    } finally {
      fs.closeSync(file);
    }
    return buffer;
  }

  private static removeTree(path: string): void {
    try {
      fs.rmdirSync(path);
    } catch (error) {
      // Not present.
    }
  }
}
