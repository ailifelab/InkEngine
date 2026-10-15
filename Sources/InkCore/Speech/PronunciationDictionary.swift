import Foundation

public struct PronunciationRule: Codable, Identifiable, Sendable, Equatable {
    public let phrase: String
    public let spoken: String
    public var id: String { phrase }
    public init(phrase: String, spoken: String) { self.phrase = phrase; self.spoken = spoken }
    public var isValid: Bool { !phrase.isEmpty && !spoken.isEmpty && phrase.count <= 80 && spoken.count <= 120 && !phrase.contains(where: \.isNewline) && !spoken.contains(where: \.isNewline) }
}

/// 各朗读后端共用的词组纠音。只生成临时语音输入；原文和 UTF-16 位置不变。
/// 使用同音单字锁定目标读音，比全局替换一个多音字更能保留上下文。
public struct PronunciationDictionary: Sendable {
    public let rules: [PronunciationRule]
    private let byFirst: [Character: [PronunciationRule]]
    public init(custom: [PronunciationRule] = []) {
        var merged = Dictionary(uniqueKeysWithValues: Self.builtins.map { ($0.phrase, $0) })
        for rule in custom where rule.isValid { merged[rule.phrase] = rule }
        rules = merged.values.sorted { $0.phrase.count == $1.phrase.count ? $0.phrase < $1.phrase : $0.phrase.count > $1.phrase.count }
        byFirst = Dictionary(grouping: rules, by: { $0.phrase.first! })
    }
    public func applying(to text: String) -> String {
        var output = "", index = text.startIndex
        output.reserveCapacity(text.utf8.count)
        while index < text.endIndex {
            // 最长词组优先且只扫描原文一次，避免替换后的同音字再次命中规则。
            if let rule = byFirst[text[index]]?.first(where: { text[index...].hasPrefix($0.phrase) }) {
                output += rule.spoken; index = text.index(index, offsetBy: rule.phrase.count)
            } else { output.append(text[index]); index = text.index(after: index) }
        }
        return output
    }
    public var cacheKey: String { Manuscript.digest(rules.map { $0.phrase + "=" + $0.spoken }.joined(separator: "\n")) }

    public static let builtins: [PronunciationRule] = {
        var words: [String: String] = [:]
        func group(_ phrases: String, _ old: String, _ spoken: String) {
            for phrase in phrases.split(separator: " ").map(String.init) { words[phrase] = phrase.replacingOccurrences(of: old, with: spoken) }
        }
        // 行列 háng 与行走 xíng 必须按词组区分；同行、行为、行事等歧义词不覆盖。
        group("折行 换行 行列 行数 行号 行距 行尾 行首 空行 单行 多行 逐行 首行 按行 隔行 银行 行业 行会 行规 行情", "行", "航")
        group("一行文字 两行文字 三行文字 这一行 那一行 第几行 第一行 第二行 第三行 行长", "行", "航")
        words["行长"] = "航掌"
        group("长大 成长 长官 长者 长辈 长老 长孙 校长 队长 船长 部长 族长 院长 厂长 班长 会长 首长 家长 组长 连长 排长 营长 团长 师长 军长 局长 站长 店长 县长 市长 省长 议长", "长", "掌")
        group("重新 重复 重来 重返 重逢 重叠 重合 重温 重建 重组 重启 重生 重演 重现 重读 重写 重阳 重庆 重围 双重 多重 千重 万重", "重", "崇")
        group("重要 重量 重大 重视 重心 重点 沉重 稳重 庄重 尊重 慎重 体重 负重 重任 重病 严重 重伤 贵重 珍重 郑重 隆重 器重 看重 重压", "重", "众")
        group("音乐 乐队 乐器 乐谱 乐章 乐曲 乐坛 乐师 声乐 器乐 管乐 弦乐 奏乐 配乐 交响乐 民乐 雅乐 礼乐", "乐", "月")
        group("睡觉 午觉 懒觉 一觉", "觉", "叫")
        group("觉得 觉醒 感觉 知觉 视觉 听觉 触觉 嗅觉 察觉 发觉 自觉 直觉 警觉 错觉", "觉", "决")
        group("调整 调节 协调 调皮 调和 调解 调理 调整好 空调 失调 调试", "调", "条")
        group("声调 曲调 音调 调动 调拨 调查 调度 调任 调兵 调遣 调职 低调 高调 强调 步调 格调 论调 色调 腔调", "调", "吊")
        group("收藏 隐藏 躲藏 藏身 藏书 藏匿 藏好 珍藏 储藏 埋藏 窝藏 私藏 深藏 暗藏", "藏", "仓")
        group("西藏 藏族 藏民 藏语 藏传 宝藏 地藏 大藏经 三藏 道藏 藏文", "藏", "葬")
        group("藏经 藏经阁", "藏", "仓")
        group("数不清 数一数 数得清 数落 数钱 数星星 数人数 数到 数完 屈指可数 如数家珍 不计其数", "数", "鼠")
        words["数数"] = "鼠术"; words["不计其数"] = "不计其术"
        group("出差 差事 差使 公差 钦差 差役 差遣", "差", "拆")
        group("差别 差距 差异 偏差 误差 温差 时差 顺差 逆差", "差", "插")
        group("差劲 差不多 太差 差点 差了 很差 差远", "差", "岔")
        group("传说 传来 传递 传播 流传 传承 传授 传闻 传奇 传达 宣传 相传 传染 传送 传话 传信 传音 失传 传家", "传", "船")
        group("自传 传记 列传 人物传 外传 正传", "传", "篆")
        group("住宿 宿命 宿敌 宿愿 宿主 宿营 留宿 寄宿 投宿 夜宿 露宿 借宿 宿舍", "宿", "素")
        words["宿舍"] = "素社"
        group("星宿 二十八宿", "宿", "秀")
        group("一宿 半宿 两宿 三宿", "宿", "朽")
        group("反省 自省 省察 内省 省悟", "省", "醒")
        group("首都 都市 都城 京都 故都 国都 大都 帝都 建都 定都", "都", "督")
        group("供给 补给 自给 给养 给付 配给 给水", "给", "挤")
        group("奇数 奇偶", "奇", "基")
        group("归还 还款 还钱 还书 偿还 还债 奉还 退还 交还 返还 还礼 还手 还击 还原 生还 还乡", "还", "环")
        group("还有 还好 还是 还要 还能 还没 还可以", "还", "孩")
        group("薄弱 单薄 刻薄 微薄 薄情 鄙薄 菲薄 薄礼 轻薄 薄膜", "薄", "博")
        group("薄纸 薄片 薄饼 厚薄 薄板 薄层 薄被", "薄", "雹")
        group("参加 参考 参谋 参军 参拜 参观 参赛 参照 参政 参选 参战", "参", "餐")
        group("人参 海参 党参 沙参 丹参 参茸", "参", "申")
        group("翘首 翘楚 翘盼", "翘", "桥")
        group("翘起 翘尾 翘脚 翘腿 翘辫子", "翘", "窍")
        group("咽下 吞咽 狼吞虎咽 下咽 咽口水", "咽", "宴")
        group("咽喉 咽部 鼻咽", "咽", "烟")
        group("哽咽 呜咽 悲咽 抽咽", "咽", "夜")
        group("结实 结巴 结结巴巴 开花结果", "结", "街")
        group("结论 结局 结束 结合 结婚 结拜 团结 凝结 冻结 结伴 结算 结界 结盟 结怨", "结", "洁")
        group("暴露 露水 露出 露天 泄露 透露 显露 流露 披露 裸露 露珠 露营", "露", "路")
        group("露面 露馅 露怯 露马脚", "露", "漏")
        group("率领 率先 表率 统率 率队 率部", "率", "帅")
        group("效率 概率 频率 比率 税率 利率 汇率 速率 斜率 功率 几率 出勤率", "率", "律")
        group("降落 落地 落叶 落日 落幕 落下 落后 落款 落座 落脚 落笔 落花 部落 失落", "落", "洛")
        words["落枕"] = "涝枕"; words["落下病根"] = "涝下病根"; words["丢三落四"] = "丢三辣四"
        group("厌恶 可恶 深恶痛绝 痛恶 憎恶 好恶", "恶", "务")
        group("恶人 恶意 邪恶 凶恶 罪恶 恶毒 恶劣 恶魔 恶鬼 恶梦 丑恶 作恶 恶果", "恶", "饿")
        group("弹琴 弹奏 弹指 弹劾 弹唱 弹性 弹力 弹簧 弹跳 弹射 反弹", "弹", "谈")
        group("子弹 炸弹 弹药 炮弹 导弹 弹头 弹丸 枪弹 实弹 手榴弹 核弹", "弹", "蛋")
        group("干燥 干净 干旱 干杯 饼干 干枯 干涸 干粮 干柴 干草 晒干 风干 干燥剂", "干", "甘")
        group("干部 干活 干事 干劲 能干 干什么 干脆 干涉 干扰 树干 骨干 才干 实干 干将", "干", "赣")
        // 干脆、干涉、干扰均读 gān，不随 gàn 组改变；干将也是常见歧义词。
        for phrase in ["干脆", "干涉", "干扰", "干将"] { words.removeValue(forKey: phrase) }
        group("干脆 干涉 干扰", "干", "甘")
        words["和面"] = "活面"; words["和稀泥"] = "货稀泥"; words["唱和"] = "唱贺"; words["应和"] = "映贺"; words["好恶"] = "耗务"
        words["单于"] = "蝉于"; words["单雄信"] = "善雄信"; words["单田芳"] = "善田芳"; words["单姓"] = "善姓"
        words["曾国藩"] = "增国藩"; words["曾参"] = "增申"; words["曾姓"] = "增姓"
        // 这些短词在普通句子中也有另一种正确读法，交给后端上下文判断。
        // 例如“大都去过”“公差尺寸”“重读音节”，不能套用首都、差遣、重读一遍的读音。
        for phrase in ["单行", "重读", "千重", "万重", "公差", "大都", "给水", "地藏", "厚薄", "行长"] { words.removeValue(forKey: phrase) }
        words["单行文本"] = "单航文本"; words["单行模式"] = "单航模式"
        words["银行行长"] = "银航航掌"; words["值班的行长"] = "值班的航掌"
        words["地藏王"] = "地葬王"; words["地藏菩萨"] = "地葬菩萨"
        return words.sorted { $0.key < $1.key }.map { PronunciationRule(phrase: $0.key, spoken: $0.value) }
    }()
}
