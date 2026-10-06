// Cura-style slicing settings shown in the side panel. Values are sent to CuraEngine as
// `-s key=value` overrides on top of the generated default profile.

@Observed
export class SlicerSetting {
  key: string;
  label: string;
  group: string;
  value: number;
  isInteger: boolean;

  constructor(key: string, label: string, group: string, value: number, isInteger: boolean) {
    this.key = key;
    this.label = label;
    this.group = group;
    this.value = value;
    this.isInteger = isInteger;
  }

  // CuraEngine's command line parser expects plain numbers; integers must not gain a decimal point
  // only when the engine would otherwise mis-parse them, so a trimmed representation is used.
  toOverride(): string {
    const text: string = this.isInteger ? Math.round(this.value).toString() : this.value.toString();
    return `${this.key}=${text}`;
  }

  adjust(delta: number): void {
    const step: number = this.isInteger ? 1 : 0.05;
    const next: number = this.value + delta * step;
    this.value = next < 0 ? 0 : Math.round(next * 1000) / 1000;
  }
}

export const SETTING_GROUPS: string[] = ['质量', '填充', '材料', '速度', '机器'];

export function createDefaultSettings(): SlicerSetting[] {
  return [
    new SlicerSetting('layer_height', '层高', '质量', 0.2, false),
    new SlicerSetting('layer_height_0', '首层高', '质量', 0.2, false),
    new SlicerSetting('wall_thickness', '壁厚', '质量', 1.2, false),
    new SlicerSetting('infill_sparse_density', '填充密度', '填充', 20, true),
    new SlicerSetting('material_print_temperature', '喷嘴温度', '材料', 200, true),
    new SlicerSetting('material_bed_temperature', '热床温度', '材料', 60, true),
    new SlicerSetting('speed_print', '打印速度', '速度', 50, true),
    new SlicerSetting('speed_travel', '空驶速度', '速度', 120, true),
    new SlicerSetting('machine_width', '成型尺寸 X', '机器', 200, true),
    new SlicerSetting('machine_depth', '成型尺寸 Y', '机器', 200, true),
    new SlicerSetting('machine_height', '成型高度 Z', '机器', 200, true),
  ];
}
