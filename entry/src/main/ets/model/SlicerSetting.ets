// Cura-style slicing settings shown in the side panel. Values are sent to CuraEngine as
// `-s key=value` overrides on top of the generated default profile.

@Observed
export class SlicerSetting {
  key: string;
  label: string;
  group: string;
  value: number;
  isInteger: boolean;
  step: number;
  //! Notifies the owner so derived side effects (for example the preview build plate) can refresh.
  onChanged?: () => void;

  constructor(key: string, label: string, group: string, value: number, isInteger: boolean, step?: number) {
    this.key = key;
    this.label = label;
    this.group = group;
    this.value = value;
    this.isInteger = isInteger;
    this.step = step !== undefined ? step : (isInteger ? 1 : 0.05);
  }

  // CuraEngine's command line parser expects plain numbers; integers must not gain a decimal point
  // only when the engine would otherwise mis-parse them, so a trimmed representation is used.
  toOverride(): string {
    const text: string = this.isInteger ? Math.round(this.value).toString() : this.value.toString();
    return `${this.key}=${text}`;
  }

  setValue(next: number): void {
    this.value = next < 0 ? 0 : Math.round(next * 1000) / 1000;
    this.onChanged?.();
  }

  adjust(delta: number): void {
    this.setValue(this.value + delta * this.step);
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
    new SlicerSetting('machine_width', '打印宽度', '机器', 180, true, 10),
    new SlicerSetting('machine_depth', '打印深度', '机器', 180, true, 10),
    new SlicerSetting('machine_height', '打印高度', '机器', 180, true, 10),
  ];
}
