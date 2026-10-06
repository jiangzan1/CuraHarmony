import { SETTING_GROUPS, SlicerSetting } from '../model/SlicerSetting';
import { SettingRow } from './SettingRow';

// Cura-style settings sidebar: collapsible-looking group headers with the editable settings below.
@Component
export struct SettingsPanel {
  @Link settings: SlicerSetting[];

  @Builder
  groupSection(groupName: string) {
    Column() {
      Text(groupName)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#e6e8ec')
        .width('100%')
        .padding({ top: 12, bottom: 6 })
      ForEach(this.settings.filter((item: SlicerSetting): boolean => item.group === groupName),
        (item: SlicerSetting) => {
          SettingRow({ setting: item })
        },
        (item: SlicerSetting): string => item.key)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Text('打印设置')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#ffffff')
        .width('100%')
        .padding({ bottom: 4 })
      ForEach(SETTING_GROUPS, (groupName: string) => {
        this.groupSection(groupName)
      }, (groupName: string): string => groupName)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
