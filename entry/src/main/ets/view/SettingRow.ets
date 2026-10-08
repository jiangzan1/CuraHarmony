import { SlicerSetting } from '../model/SlicerSetting';

// One editable numeric setting, laid out like a Cura setting row: label on the left, value on the
// right with small decrement/increment controls.
@Component
export struct SettingRow {
  @ObjectLink setting: SlicerSetting;

  build() {
    Row({ space: 6 }) {
      Text(this.setting.label)
        .fontSize(13)
        .fontColor('#c8ccd4')
        .layoutWeight(1)
        .maxLines(1)

      Button('-')
        .fontSize(16)
        .fontColor('#e6e8ec')
        .width(28)
        .height(28)
        .padding(0)
        .backgroundColor('#2a2d33')
        .onClick(() => {
          this.setting.adjust(-1);
        })

      TextInput({ text: this.setting.value.toString() })
        .type(InputType.Normal)
        .fontSize(13)
        .width(76)
        .height(30)
        .backgroundColor('#1c1f24')
        .fontColor('#e6e8ec')
        .textAlign(TextAlign.Center)
        .onChange((value: string) => {
          const parsed: number = Number.parseFloat(value);
          if (!Number.isNaN(parsed) && parsed >= 0) {
            this.setting.setValue(parsed);
          }
        })

      Button('+')
        .fontSize(16)
        .fontColor('#e6e8ec')
        .width(28)
        .height(28)
        .padding(0)
        .backgroundColor('#2a2d33')
        .onClick(() => {
          this.setting.adjust(1);
        })
    }
    .width('100%')
    .height(36)
  }
}
