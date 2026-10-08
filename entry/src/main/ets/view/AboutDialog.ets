import { APP_NAME, APP_VERSION, LICENSE_TEXT, PRIVACY_SUMMARY, SOURCE_URL } from '../model/AppInfo';

// Store-required "about" entry: version, privacy summary and the open-source licence notice
// (including the AGPL-3.0 source offer).
@CustomDialog
export struct AboutDialog {
  controller: CustomDialogController;

  @Builder
  section(title: string, body: string) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#e6e8ec')
        .width('100%')
      Text(body)
        .fontSize(12)
        .fontColor('#c8ccd4')
        .width('100%')
        // Long URLs have no break opportunity; without this the text grows wider than the dialog and
        // the centred content gets clipped on the left.
        .wordBreak(WordBreak.BREAK_ALL)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 10 }) {
      Text(`关于 ${APP_NAME}`)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#ffffff')
        .width('100%')
      Text(`版本 ${APP_VERSION}`)
        .fontSize(12)
        .fontColor('#8b9099')
        .width('100%')

      Scroll() {
        Column({ space: 12 }) {
          this.section('隐私说明', PRIVACY_SUMMARY)
          this.section('开源许可', LICENSE_TEXT)
          this.section('源码地址', SOURCE_URL)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(320)
      .scrollBar(BarState.Auto)

      Button('关闭')
        .fontSize(14)
        .height(34)
        .width('100%')
        .backgroundColor('#2f6fd0')
        .onClick(() => {
          this.controller.close();
        })
    }
    .width(560)
    .padding(18)
    .backgroundColor('#1b1e23')
    .borderRadius(12)
  }
}
