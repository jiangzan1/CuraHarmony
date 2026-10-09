import { zlib } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

// Converts a 3MF package into a binary STL.
//
// CuraEngine's mesh loader only understands STL/OBJ (see third_party/CuraEngine/src/MeshGroup.cpp),
// so a 3MF must be flattened to a mesh file before previewing or slicing. A 3MF is a zip whose
// 3D/3dmodel.model is XML; the triangles are copied into a binary STL that the existing pipeline
// already handles.
//
// Everything is inlined into this @Concurrent function on purpose: a TaskPool task may only use
// imported modules and other concurrent functions, so helpers cannot be shared with the UI thread.
@Concurrent
async function convert3mfTask(zipPath: string, tmpDir: string, stlPath: string): Promise<void> {
    await zlib.decompressFile(zipPath, tmpDir);

    // The model part is usually 3D/3dmodel.model; fall back to any *.model under 3D/.
    let modelPath: string = `${tmpDir}/3D/3dmodel.model`;
    if (!fs.accessSync(modelPath)) {
        const files: string[] = fs.listFileSync(`${tmpDir}/3D`);
        for (const fileName of files) {
            if (fileName.endsWith('.model')) {
                modelPath = `${tmpDir}/3D/${fileName}`;
                break;
            }
        }
    }
    const xml: string = fs.readTextSync(modelPath);

    // <model unit="..."> defaults to millimeter; convert everything to millimetres for slicing.
    let scale: number = 1.0;
    const unitMatch: RegExpMatchArray | null = xml.match(/<model[^>]*unit="([a-zA-Z]+)"/);
    if (unitMatch !== null) {
        const unit: string = unitMatch[1];
        if (unit === 'micron') {
            scale = 0.001;
        } else if (unit === 'centimeter') {
            scale = 10.0;
        } else if (unit === 'inch') {
            scale = 25.4;
        } else if (unit === 'foot') {
            scale = 304.8;
        } else if (unit === 'meter') {
            scale = 1000.0;
        }
    }

    const xs: number[] = [];
    const ys: number[] = [];
    const zs: number[] = [];
    const vertexPattern: RegExp = /<vertex\s+([^>]*?)\/?>/g;
    let vertexMatch: RegExpExecArray | null = vertexPattern.exec(xml);
    while (vertexMatch !== null) {
        const attributes: string = vertexMatch[1];
        const xMatch: RegExpMatchArray | null = attributes.match(/x="([^"]*)"/);
        const yMatch: RegExpMatchArray | null = attributes.match(/y="([^"]*)"/);
        const zMatch: RegExpMatchArray | null = attributes.match(/z="([^"]*)"/);
        xs.push((xMatch !== null ? Number.parseFloat(xMatch[1]) : 0.0) * scale);
        ys.push((yMatch !== null ? Number.parseFloat(yMatch[1]) : 0.0) * scale);
        zs.push((zMatch !== null ? Number.parseFloat(zMatch[1]) : 0.0) * scale);
        vertexMatch = vertexPattern.exec(xml);
    }

    const indexA: number[] = [];
    const indexB: number[] = [];
    const indexC: number[] = [];
    const trianglePattern: RegExp = /<triangle\s+([^>]*?)\/?>/g;
    let triangleMatch: RegExpExecArray | null = trianglePattern.exec(xml);
    while (triangleMatch !== null) {
        const attributes: string = triangleMatch[1];
        const v1Match: RegExpMatchArray | null = attributes.match(/v1="([^"]*)"/);
        const v2Match: RegExpMatchArray | null = attributes.match(/v2="([^"]*)"/);
        const v3Match: RegExpMatchArray | null = attributes.match(/v3="([^"]*)"/);
        if (v1Match !== null && v2Match !== null && v3Match !== null) {
            const a: number = Number.parseInt(v1Match[1], 10);
            const b: number = Number.parseInt(v2Match[1], 10);
            const c: number = Number.parseInt(v3Match[1], 10);
            if (a >= 0 && b >= 0 && c >= 0 && a < xs.length && b < xs.length && c < xs.length) {
                indexA.push(a);
                indexB.push(b);
                indexC.push(c);
            }
        }
        triangleMatch = trianglePattern.exec(xml);
    }

    if (indexA.length === 0) {
        throw new Error('3MF 中未找到三角网格');
    }

    // Binary STL: 80-byte header + uint32 count + 50 bytes per triangle.
    const buffer: ArrayBuffer = new ArrayBuffer(84 + indexA.length * 50);
    const view: DataView = new DataView(buffer);
    view.setUint32(80, indexA.length, true);
    let offset: number = 84;
    for (let i = 0; i < indexA.length; i++) {
        const ai: number = indexA[i];
        const bi: number = indexB[i];
        const ci: number = indexC[i];
        const ax: number = xs[ai];
        const ay: number = ys[ai];
        const az: number = zs[ai];
        const bx: number = xs[bi];
        const by: number = ys[bi];
        const bz: number = zs[bi];
        const cx: number = xs[ci];
        const cy: number = ys[ci];
        const cz: number = zs[ci];

        const ux: number = bx - ax;
        const uy: number = by - ay;
        const uz: number = bz - az;
        const vx: number = cx - ax;
        const vy: number = cy - ay;
        const vz: number = cz - az;
        let nx: number = uy * vz - uz * vy;
        let ny: number = uz * vx - ux * vz;
        let nz: number = ux * vy - uy * vx;
        const length: number = Math.sqrt(nx * nx + ny * ny + nz * nz);
        if (length > 0.0) {
            nx = nx / length;
            ny = ny / length;
            nz = nz / length;
        } else {
            nx = 0.0;
            ny = 0.0;
            nz = 0.0;
        }

        view.setFloat32(offset, nx, true);
        view.setFloat32(offset + 4, ny, true);
        view.setFloat32(offset + 8, nz, true);
        view.setFloat32(offset + 12, ax, true);
        view.setFloat32(offset + 16, ay, true);
        view.setFloat32(offset + 20, az, true);
        view.setFloat32(offset + 24, bx, true);
        view.setFloat32(offset + 28, by, true);
        view.setFloat32(offset + 32, bz, true);
        view.setFloat32(offset + 36, cx, true);
        view.setFloat32(offset + 40, cy, true);
        view.setFloat32(offset + 44, cz, true);
        view.setUint16(offset + 48, 0, true);
        offset += 50;
    }

    const file = fs.openSync(stlPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
        fs.writeSync(file.fd, buffer);
    } finally {
        fs.closeSync(file);
    }
}

// 3MF import helper used by the page: unzips, parses and writes a binary STL next to the other
// sandbox model files.
export class Mesh3mf {
    static async convertToStl(zipPath: string, workDir: string, stlPath: string): Promise<number> {
        const tmpDir: string = `${workDir}/3mf_tmp`;
        try {
            fs.rmdirSync(tmpDir);
        } catch (error) {
            // Not present yet: nothing to clean.
        }

        try {
            const task: taskpool.Task = new taskpool.Task(convert3mfTask, zipPath, tmpDir, stlPath);
            await taskpool.execute(task);
        } catch (error) {
            const err = error as BusinessError;
            hilog.warn(DOMAIN, 'Mesh3mf', 'TASKPOOL_FAIL %{public}s, converting inline', err.message);
            await convert3mfTask(zipPath, tmpDir, stlPath);
        }

        let triangles: number = 0;
        try {
            const size: number = fs.statSync(stlPath).size;
            triangles = size > 84 ? Math.floor((size - 84) / 50) : 0;
        } catch (error) {
            triangles = 0;
        }

        try {
            fs.rmdirSync(tmpDir);
        } catch (error) {
            // Best-effort cleanup.
        }
        return triangles;
    }
}
