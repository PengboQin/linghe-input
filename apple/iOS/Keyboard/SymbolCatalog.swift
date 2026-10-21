import Foundation

struct SymbolCategory {
    let id: String
    let title: String
    let symbols: [String]
}

enum SymbolCatalog {
    static let numericRail = [".", "@", "-", "+", "/", ":", "%", ",", "=", "(", ")", "*", "#", "$", "¥"]
    private static func category(_ id: String, _ title: String, _ text: String) -> SymbolCategory {
        var seen = Set<String>()
        return SymbolCategory(id: id, title: title, symbols: text.map(String.init).filter { seen.insert($0).inserted })
    }
    static let categories: [SymbolCategory] = [
        category("common", "常用", "，。！？、；：…—～（）【】《》“”‘’·@#&％＋－×÷＝￥$€£①②③④⑤•○●□■→←↑↓"),
        category("chinese", "中文", "，。！？、；：…—～·‧﹏（）【】〔〕［］｛｝〈〉《》「」『』〖〗〘〙〚〛“”‘’﹃﹄﹁﹂﹙﹚﹛﹜﹝﹞／＼｜＃＆＊％＠＿＋－＝"),
        category("english", "英文", ",.!?:;\"'`()[]{}<>/\\|@#&*_+-=~^%$"),
        category("bullets", "项目", "•◦‣⁃∙·●○◉◎◌◍◯▪▫■□▢▣▤▥▦▧▨▩◆◇◈♦♢▲△▶▷▼▽◀◁★☆✦✧✪✩✓✔☑☐☒✕✖✗✘❖※†‡"),
        category("numbered", "序号", "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳㉑㉒㉓㉔㉕㉖㉗㉘㉙㉚❶❷❸❹❺❻❼❽❾❿⑴⑵⑶⑷⑸⑹⑺⑻⑼⑽ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ"),
        category("math", "数学", "+−×÷=≠≈≃≅≡≢≒≌<>≤≥≪≫±∓√∛∜∞∝∑∏∫∬∭∮∂∆∇π∈∉∋∅∩∪⊂⊃⊆⊇∀∃∄∴∵∧∨¬⊕⊗⊙⊥∥∠∟⌒%‰‱¹²³⁴⁵⁶⁷⁸⁹⁰₁₂₃₄₅₆₇₈₉₀½⅓⅔¼¾⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞"),
        category("arrows", "箭头", "←↑→↓↔↕↖↗↘↙↚↛↜↝↞↟↠↡↢↣↤↥↦↧↩↪↫↬↭↯↰↱↲↳↴↵⇄⇅⇆⇇⇈⇉⇊⇋⇌⇐⇑⇒⇓⇔⇕⇖⇗⇘⇙⇠⇡⇢⇣⇤⇥⇦⇧⇨⇩➜➝➞➟➠➡➢➤⟵⟶⟷"),
        category("currency", "货币", "¥￥$¢€£₩₽₹₫฿₱₺₴₦₭₮₡₲₵₸₼₾¤"),
        category("units", "单位", "°℃℉％‰‱㎜㎝㎞㎡㎥㎎㎏㏄㏎㏑㏒㏕㎖㎗㎘㎅㎆㎇㎐㎑㎒㎓㎔㎧㎨㎪㎫㎬㎭㎮㎯㎰㎱㎲㎳㎴㎵㎶㎷㎸㎹㎺㎻㎼㎽㎾㎿㍱㍲㍳㍴㍵㍶ℓΩ℧µÅ″′"),
        category("greek", "希腊", "αβγδεζηθικλμνξοπρστυφχψωΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ"),
        category("lines", "制表", "─━│┃┄┅┆┇┈┉┊┋┌┍┎┏┐┑┒┓└┕┖┗┘┙┚┛├┝┞┟┠┡┢┣┤┥┦┧┨┩┪┫┬┭┮┯┰┱┲┳┴┵┶┷┸┹┺┻┼┽┾┿╀╁╂╃╄╅╆╇╈╉╊╋═║╔╗╚╝╠╣╦╩╬╭╮╯╰╱╲╳"),
        category("special", "特殊", "©®™℠℗℅℆№℡℻℞℟℣℥℮℔℘ℑℜℵℶℷℸ§¶†‡※〃々〆〄〓〠〶〒〰⌘⌥⇧⌃⌫⌦⎋⏎␣⌂⌐⌑⌕⌖⌗⌙⌜⌝⌞⌟⌠⌡⌢⌣⌤⌧〈〉☀☁☂☃☄☇☈☉☊☋☌☍☐☑☒☓☕☘☙☞☜☝☟♠♡♢♣♤♥♦♧♩♪♫♬♭♮♯⚑⚐⚠⚡⚙⚖⚗⚛⚜⚝⚞⚟")
    ]
}
