// Store-facing application metadata and the compliance texts shown in the privacy prompt and the
// "about" dialog. Update SOURCE_URL and the privacy URL before submitting to an app market.

export const APP_NAME: string = 'CuraHarmony';
export const APP_VERSION: string = '1.0.0';
export const SOURCE_URL: string = 'https://gitee.com/your-account/CuraHarmony';
export const PRIVACY_URL: string = 'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2056798714009282496';

export const PRIVACY_SUMMARY: string =
  '本应用不申请网络权限，不采集、不上传任何个人信息，不含广告与第三方统计。\n\n' +
  '导入的 STL 模型与生成的 G-code 仅保存在本机应用沙箱内，卸载即删除。\n\n' +
  'USB 串口仅在你主动点击“连接”时由你授权，用于向 3D 打印机发送 G-code。\n\n' +
  `完整隐私政策：${PRIVACY_URL}`;

export const LICENSE_TEXT: string =
  '本应用基于以下开源项目构建，并按各自许可证分发：\n\n' +
  '• Cura / CuraEngine —— AGPL-3.0\n' +
  '• fmt (MIT)、oneTBB (Apache-2.0)、Boost (BSL-1.0)、Clipper (BSL-1.0)\n' +
  '• zlib、libpng、range-v3 (BSL-1.0)、rapidjson (MIT)\n' +
  '• stb、spdlog (MIT)、mapbox wagyu (ISC)、mapbox geometry (ISC)\n\n' +
  '依据 AGPL-3.0，完整对应源码获取地址：\n' +
  `${SOURCE_URL}\n\n` +
  '“Cura”为 Ultimaker 的商标，本应用与 Ultimaker 无从属关系。';
