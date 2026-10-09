#!/usr/bin/env python3
"""Generate the AGC self-test document (docx) without third-party libraries.

Builds a minimal, valid WordprocessingML package with zipfile. The document explains how the
reviewer can verify the app, and which steps need a physical 3D printer.
"""
from __future__ import annotations

import pathlib
import zipfile

OUT = pathlib.Path(r"E:\Users\jiangzan\cura\证书\CuraHarmony-自测说明.docx")

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>"""

RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>"""

# (level, text): level 0 = title, 1 = heading, 2 = body
DOC: list[tuple[int, str]] = [
    (0, "CuraHarmony 自测说明（提交审核）"),
    (1, "一、应用信息"),
    (2, "应用名称：CuraHarmony"),
    (2, "包名：com.jiangzan.curaharmony"),
    (2, "版本：1.1.0"),
    (2, "适用设备：2in1（PC / 二合一电脑）、平板、手机"),
    (2, "功能差异：USB 串口打印仅限 2in1（PC）；平板与手机不显示打印机面板、不提供打印功能"),
    (2, "是否联网：否（应用未申请网络权限，不具备联网能力）"),
    (2, "是否需要注册/登录：否"),
    (1, "二、运行环境说明"),
    (2, "1. 需要一台 HarmonyOS 设备（2in1 / 平板 / 手机均可验证导入、预览与切片）。"),
    (2, "2. 除“USB 串口打印”外，其余功能无需任何外部设备即可完整验证。"),
    (2, "3. “USB 串口打印”仅 2in1（PC）提供，需连接一台 Marlin 固件的 3D 打印机"
        "（USB 串口，波特率 115200）。若审核环境没有打印机，该步骤可跳过，其余步骤均可独立验证。"),
    (2, "4. 平板/手机：界面为移动端布局（预览全屏 + 可收起的底部“面板”），不包含任何打印相关入口。"),
    (1, "三、自测步骤（无需打印机）"),
    (2, "步骤 1  启动应用：首次启动会弹出“隐私政策”对话框，点击“同意”。"
        "预期进入主界面：顶部为 CuraHarmony 标题与 导入模型 / 切片 / 模式：旋转 / 关于 按钮；"
        "左侧为“打印机”“打印设置”面板；中间为 3D 预览，显示一个立方体与打印平台网格。"),
    (2, "步骤 2  3D 预览交互：在中间预览区按住拖动可旋转视角；触屏双指捏合可缩放；"
        "点击顶部“模式：旋转”切换到“模式：移动”后，拖动可在打印平台上平移模型。"),
    (2, "步骤 3  调整打印机尺寸：在左侧“机器”分组修改“打印宽度 / 打印深度”"
        "（可用 +/- 按钮或直接输入数值），预期中间的打印平台网格随尺寸实时变宽/变窄。"),
    (2, "步骤 4  导入模型：点击“导入模型”，通过系统文件选择器选择任意 .stl 文件；"
        "预期预览更新为该模型并自动居中到平台。也可不导入，直接使用内置示例模型进行验证。"),
    (2, "步骤 5  切片：点击“切片”按钮；预期按钮变为“切片中…”，随后底部状态栏显示"
        "“切片成功：xxxxx 字节 / xxxxx 层”。"),
    (2, "步骤 6  关于：点击“关于”按钮，预期弹出对话框，显示版本号、隐私说明、开源许可与源码地址；"
        "点击“关闭”可关闭。"),
    (1, "四、USB 串口打印（需连接打印机，无设备可跳过）"),
    (2, "步骤 1  用 USB 线把 Marlin 固件的 3D 打印机连接到 2in1 设备。"),
    (2, "步骤 2  在“打印机”面板点击“刷新端口”，在端口列表中选择对应串口（设备名形如 3-2），"
        "点击“连接”，并在系统弹窗中允许串口访问。"),
    (2, "步骤 3  连接成功后，面板显示固件信息与实时喷嘴/热床温度，“最近回应”显示打印机返回的内容。"),
    (2, "步骤 4  先完成“切片”以生成 G-code，再点击“打印”。"),
    (2, "步骤 5  预期：打印机先加热到目标喷嘴温度，随后归零（G28）并按起始 G-code 开始打印；"
        "面板“进度”随已确认行数增长；“暂停”“取消”按钮可用。"),
    (1, "五、其他说明"),
    (2, "1. 本应用不采集个人信息、无网络权限、无第三方 SDK、无广告。"),
    (2, "2. 所有模型文件与生成的 G-code 仅保存在本机应用沙箱内，卸载即删除。"),
    (2, "3. 隐私政策：https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2056798714009282496"),
    (2, "4. 对应源码（AGPL-3.0）：https://github.com/jiangzan1/CuraHarmony"),
]


def esc(text: str) -> str:
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def para(level: int, text: str) -> str:
    if level == 0:
        props = '<w:pPr><w:spacing w:after="240"/></w:pPr>'
        run = f'<w:r><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr><w:t xml:space="preserve">{esc(text)}</w:t></w:r>'
    elif level == 1:
        props = '<w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr>'
        run = f'<w:r><w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr><w:t xml:space="preserve">{esc(text)}</w:t></w:r>'
    else:
        props = '<w:pPr><w:spacing w:after="80"/></w:pPr>'
        run = f'<w:r><w:rPr><w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr><w:t xml:space="preserve">{esc(text)}</w:t></w:r>'
    return f"<w:p>{props}{run}</w:p>"


def main() -> int:
    body = "".join(para(level, text) for level, text in DOC)
    document = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body>{body}"
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr>'
        "</w:body></w:document>"
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", CONTENT_TYPES)
        zf.writestr("_rels/.rels", RELS)
        zf.writestr("word/document.xml", document)
    print(f"Wrote {OUT} ({OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
