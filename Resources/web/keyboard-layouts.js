// On-screen keyboard layouts for the language mentor: one entry per language the learner may be learning, keyed by
// ISO 639-1 code. The transcript page (components/keyboard.js) and the app's composer (Swift, KeyboardLayouts) both read
// this file, so the data is the plain JSON object after the `=` and nothing else may follow it.
//
//   name     the language's own name (shown on the panel), english: its English name
//   rows     rows of keys: a string inserts itself; {"k": …} is a function key: shift, bksp, space, enter,
//            dakuten (゛), handakuten (゜), small (ぁ), kana (ひら/カタ), tone (pinyin tone cycle), tone1…tone4 (that tone
//            on the syllable before the caret; a digit typed after a syllable does the same), mode (compose mode)
//   shift    the rows under shift (absent: shift uppercases letters when `upper` is true)
//   compose  how typed keys combine: "hangul" (jamo → syllables), "kana" (゛゜ and small forms), "pinyin" (tone marks),
//            "marks" (combining marks fold into the previous letter, e.g. Vietnamese tones, Arabic harakat),
//            "abugida" (a vowel letter typed after a consonant becomes its vowel sign: क + आ → का, as Devanagari is written)
//   modes    alternative input modes the panel offers, e.g. ["kana", "romaji"] (romaji: type Latin, get kana); a layout
//            with `physical` also offers "keys"
//   physical what the Mac's own keys type in "keys" mode: one list per row of the physical keyboard (Q…], A…', Z…/),
//            following the standard layout for the script (Arabic PC, ЙЦУКЕН, 2-set Korean, InScript, Kedmanee…), and
//            `physical_shift` for the shifted keys. The on-screen key lights up as it is typed.
//   rtl      right-to-left script
//   An empty string "" in a row is a gap that keeps a grid (the kana table) aligned.
window.TeacherKeyboardLayouts = {
  "ja": { "name": "日本語", "english": "Japanese", "compose": "kana", "modes": ["kana", "romaji"],
    "rows": [
      ["あ", "か", "さ", "た", "な", "は", "ま", "や", "ら", "わ", "ん"],
      ["い", "き", "し", "ち", "に", "ひ", "み", "", "り", "", "ー"],
      ["う", "く", "す", "つ", "ぬ", "ふ", "む", "ゆ", "る", "を", "、"],
      ["え", "け", "せ", "て", "ね", "へ", "め", "", "れ", "", "。"],
      ["お", "こ", "そ", "と", "の", "ほ", "も", "よ", "ろ", "っ", "？"],
      [{"k": "dakuten"}, {"k": "handakuten"}, {"k": "small"}, {"k": "kana"}, {"k": "space"}, {"k": "bksp"}, {"k": "mode"}]
    ] },
  "ko": { "name": "한국어", "english": "Korean", "compose": "hangul",
    "physical": [["ㅂ", "ㅈ", "ㄷ", "ㄱ", "ㅅ", "ㅛ", "ㅕ", "ㅑ", "ㅐ", "ㅔ"], ["ㅁ", "ㄴ", "ㅇ", "ㄹ", "ㅎ", "ㅗ", "ㅓ", "ㅏ", "ㅣ"], ["ㅋ", "ㅌ", "ㅊ", "ㅍ", "ㅠ", "ㅜ", "ㅡ"]],
    "physical_shift": [["ㅃ", "ㅉ", "ㄸ", "ㄲ", "ㅆ", "ㅛ", "ㅕ", "ㅑ", "ㅒ", "ㅖ"], ["ㅁ", "ㄴ", "ㅇ", "ㄹ", "ㅎ", "ㅗ", "ㅓ", "ㅏ", "ㅣ"], ["ㅋ", "ㅌ", "ㅊ", "ㅍ", "ㅠ", "ㅜ", "ㅡ"]],
    "rows": [
      ["ㅂ", "ㅈ", "ㄷ", "ㄱ", "ㅅ", "ㅛ", "ㅕ", "ㅑ", "ㅐ", "ㅔ"],
      ["ㅁ", "ㄴ", "ㅇ", "ㄹ", "ㅎ", "ㅗ", "ㅓ", "ㅏ", "ㅣ"],
      [{"k": "shift"}, "ㅋ", "ㅌ", "ㅊ", "ㅍ", "ㅠ", "ㅜ", "ㅡ", {"k": "bksp"}],
      [{"k": "space"}, ".", "?", "!"]
    ],
    "shift": [
      ["ㅃ", "ㅉ", "ㄸ", "ㄲ", "ㅆ", "ㅛ", "ㅕ", "ㅑ", "ㅒ", "ㅖ"],
      ["ㅁ", "ㄴ", "ㅇ", "ㄹ", "ㅎ", "ㅗ", "ㅓ", "ㅏ", "ㅣ"],
      [{"k": "shift"}, "ㅋ", "ㅌ", "ㅊ", "ㅍ", "ㅠ", "ㅜ", "ㅡ", {"k": "bksp"}],
      [{"k": "space"}, ".", "?", "!"]
    ] },
  "zh": { "name": "中文 · 拼音", "english": "Chinese (pinyin)", "compose": "pinyin", "upper": true,
    "rows": [
      ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
      ["a", "s", "d", "f", "g", "h", "j", "k", "l", "ü"],
      [{"k": "shift"}, "z", "x", "c", "v", "b", "n", "m", "'", {"k": "bksp"}],
      [{"k": "tone1"}, {"k": "tone2"}, {"k": "tone3"}, {"k": "tone4"}, {"k": "tone"}, {"k": "space"}, "，", "。", "？"]
    ] },
  "ar": { "name": "العربية", "english": "Arabic", "rtl": true, "compose": "marks",
    "physical": [["ض", "ص", "ث", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "د"], ["ش", "س", "ي", "ب", "ل", "ا", "ت", "ن", "م", "ك", "ط"], ["ئ", "ء", "ؤ", "ر", "لا", "ى", "ة", "و", "ز", "ظ"]],
    "physical_shift": [["َ", "ً", "ُ", "ٌ", "لإ", "إ", "‘", "÷", "×", "؛", "<", ">"], ["ِ", "ٍ", "]", "[", "لأ", "أ", "ـ", "،", "/", ":", "\""], ["~", "ْ", "}", "{", "لآ", "آ", "’", ",", ".", "؟"]],
    "rows": [
      ["ض", "ص", "ث", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "د"],
      ["ش", "س", "ي", "ب", "ل", "ا", "ت", "ن", "م", "ك", "ط"],
      ["ئ", "ء", "ؤ", "ر", "لا", "ى", "ة", "و", "ز", "ظ", {"k": "bksp"}],
      ["َ", "ً", "ُ", "ٌ", "ِ", "ٍ", "ْ", "ّ", "آ", "أ", "إ", "ٱ"],
      [{"k": "space"}, "،", "؛", "؟", "."]
    ] },
  "fa": { "name": "فارسی", "english": "Persian", "rtl": true,
    "physical": [["ض", "ص", "ث", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "چ"], ["ش", "س", "ی", "ب", "ل", "ا", "ت", "ن", "م", "ک", "گ"], ["ظ", "ط", "ز", "ر", "ذ", "د", "پ", "و", ".", "/"]],
    "rows": [
      ["ض", "ص", "ث", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "چ"],
      ["ش", "س", "ی", "ب", "ل", "ا", "ت", "ن", "م", "ک", "گ"],
      ["ظ", "ط", "ز", "ر", "ذ", "د", "پ", "و", "ژ", "ئ", {"k": "bksp"}],
      ["َ", "ُ", "ِ", "ّ", "ْ", "ً", "آ", "أ", "ء", "ة", "ي", "ك"],
      [{"k": "space"}, "،", "؛", "؟", "."]
    ] },
  "ur": { "name": "اردو", "english": "Urdu", "rtl": true,
    "rows": [
      ["ط", "ص", "ھ", "د", "ٹ", "پ", "ت", "ب", "ج", "ح", "چ", "خ"],
      ["م", "و", "ر", "ن", "ل", "ہ", "ا", "ک", "ی", "ے", "ق"],
      ["ف", "ش", "ع", "غ", "ز", "ڈ", "ڑ", "ں", "ث", "ذ", "ظ", {"k": "bksp"}],
      ["ض", "س", "گ", "ئ", "ء", "ۃ", "ؤ", "آ", "َ", "ُ", "ِ", "ّ"],
      [{"k": "space"}, "،", "۔", "؟"]
    ] },
  "he": { "name": "עברית", "english": "Hebrew", "rtl": true,
    "physical": [["/", "'", "ק", "ר", "א", "ט", "ו", "ן", "ם", "פ", "]", "["], ["ש", "ד", "ג", "כ", "ע", "י", "ח", "ל", "ך", "ף", ","], ["ז", "ס", "ב", "ה", "נ", "מ", "צ", "ת", "ץ", "."]],
    "rows": [
      ["/", "'", "ק", "ר", "א", "ט", "ו", "ן", "ם", "פ"],
      ["ש", "ד", "ג", "כ", "ע", "י", "ח", "ל", "ך", "ף"],
      ["ז", "ס", "ב", "ה", "נ", "מ", "צ", "ת", "ץ", {"k": "bksp"}],
      ["ַ", "ָ", "ֶ", "ֵ", "ִ", "ֹ", "ֻ", "ְ", "ּ", "ׁ", "ׂ", "ֲ", "ֳ", "ֱ"],
      [{"k": "space"}, ",", ".", "?", "״", "׳"]
    ] },
  "ru": { "name": "Русский", "english": "Russian", "upper": true,
    "physical": [["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х", "ъ"], ["ф", "ы", "в", "а", "п", "р", "о", "л", "д", "ж", "э"], ["я", "ч", "с", "м", "и", "т", "ь", "б", "ю", "."]],
    "physical_shift": [["Й", "Ц", "У", "К", "Е", "Н", "Г", "Ш", "Щ", "З", "Х", "Ъ"], ["Ф", "Ы", "В", "А", "П", "Р", "О", "Л", "Д", "Ж", "Э"], ["Я", "Ч", "С", "М", "И", "Т", "Ь", "Б", "Ю", ","]],
    "rows": [
      ["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х", "ъ"],
      ["ф", "ы", "в", "а", "п", "р", "о", "л", "д", "ж", "э"],
      [{"k": "shift"}, "я", "ч", "с", "м", "и", "т", "ь", "б", "ю", "ё", {"k": "bksp"}],
      [{"k": "space"}, ",", ".", "?", "!", "—"]
    ] },
  "uk": { "name": "Українська", "english": "Ukrainian", "upper": true,
    "physical": [["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х", "ї"], ["ф", "і", "в", "а", "п", "р", "о", "л", "д", "ж", "є"], ["я", "ч", "с", "м", "и", "т", "ь", "б", "ю", "."]],
    "physical_shift": [["Й", "Ц", "У", "К", "Е", "Н", "Г", "Ш", "Щ", "З", "Х", "Ї"], ["Ф", "І", "В", "А", "П", "Р", "О", "Л", "Д", "Ж", "Є"], ["Я", "Ч", "С", "М", "И", "Т", "Ь", "Б", "Ю", ","]],
    "rows": [
      ["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х", "ї"],
      ["ф", "і", "в", "а", "п", "р", "о", "л", "д", "ж", "є"],
      [{"k": "shift"}, "я", "ч", "с", "м", "и", "т", "ь", "б", "ю", "ґ", {"k": "bksp"}],
      [{"k": "space"}, ",", ".", "?", "!", "'"]
    ] },
  "el": { "name": "Ελληνικά", "english": "Greek", "upper": true,
    "physical": [[";", "ς", "ε", "ρ", "τ", "υ", "θ", "ι", "ο", "π", "[", "]"], ["α", "σ", "δ", "φ", "γ", "η", "ξ", "κ", "λ", "΄", "'"], ["ζ", "χ", "ψ", "ω", "β", "ν", "μ", ",", ".", "/"]],
    "physical_shift": [[":", "΅", "Ε", "Ρ", "Τ", "Υ", "Θ", "Ι", "Ο", "Π", "{", "}"], ["Α", "Σ", "Δ", "Φ", "Γ", "Η", "Ξ", "Κ", "Λ", "¨", "\""], ["Ζ", "Χ", "Ψ", "Ω", "Β", "Ν", "Μ", "<", ">", "?"]],
    "rows": [
      ["ς", "ε", "ρ", "τ", "υ", "θ", "ι", "ο", "π"],
      ["α", "σ", "δ", "φ", "γ", "η", "ξ", "κ", "λ"],
      [{"k": "shift"}, "ζ", "χ", "ψ", "ω", "β", "ν", "μ", {"k": "bksp"}],
      ["ά", "έ", "ή", "ί", "ό", "ύ", "ώ", "ϊ", "ϋ", "ΐ", "ΰ"],
      [{"k": "space"}, ",", ".", ";", "·"]
    ] },
  "hi": { "name": "हिन्दी", "english": "Hindi", "compose": "abugida",
    "physical": [["ौ", "ै", "ा", "ी", "ू", "ब", "ह", "ग", "द", "ज", "ड", "़"], ["ो", "े", "्", "ि", "ु", "प", "र", "क", "त", "च", "ट"], ["ॆ", "ं", "म", "न", "व", "ल", "स", ",", ".", "य"]],
    "physical_shift": [["औ", "ऐ", "आ", "ई", "ऊ", "भ", "ङ", "घ", "ध", "झ", "ढ", "ञ"], ["ओ", "ए", "अ", "इ", "उ", "फ", "ऱ", "ख", "थ", "छ", "ठ"], ["ऎ", "ँ", "ण", "ऩ", "ऴ", "ळ", "श", "ष", "।", "य़"]],
    "rows": [
      ["क", "ख", "ग", "घ", "ङ", "च", "छ", "ज", "झ", "ञ"],
      ["ट", "ठ", "ड", "ढ", "ण", "त", "थ", "द", "ध", "न"],
      ["प", "फ", "ब", "भ", "म", "य", "र", "ल", "व", "श"],
      ["ष", "स", "ह", "क्ष", "त्र", "ज्ञ", "ड़", "ढ़", "।", {"k": "bksp"}],
      ["अ", "आ", "इ", "ई", "उ", "ऊ", "ए", "ऐ", "ओ", "औ", "ऋ"],
      ["ा", "ि", "ी", "ु", "ू", "े", "ै", "ो", "ौ", "ृ", "्", "ं", "ः", "ँ"],
      [{"k": "space"}, ",", "?", "!"]
    ] },
  "bn": { "name": "বাংলা", "english": "Bengali", "compose": "abugida",
    "rows": [
      ["ক", "খ", "গ", "ঘ", "ঙ", "চ", "ছ", "জ", "ঝ", "ঞ"],
      ["ট", "ঠ", "ড", "ঢ", "ণ", "ত", "থ", "দ", "ধ", "ন"],
      ["প", "ফ", "ব", "ভ", "ম", "য", "র", "ল", "শ", "ষ"],
      ["স", "হ", "ড়", "ঢ়", "য়", "ৎ", "ং", "ঃ", "ঁ", {"k": "bksp"}],
      ["অ", "আ", "ই", "ঈ", "উ", "ঊ", "ঋ", "এ", "ঐ", "ও", "ঔ"],
      ["া", "ি", "ী", "ু", "ূ", "ৃ", "ে", "ৈ", "ো", "ৌ", "্", "।"],
      [{"k": "space"}, ",", "?", "!"]
    ] },
  "th": { "name": "ไทย", "english": "Thai",
    "physical": [["ๆ", "ไ", "ำ", "พ", "ะ", "ั", "ี", "ร", "น", "ย", "บ", "ล"], ["ฟ", "ห", "ก", "ด", "เ", "้", "่", "า", "ส", "ว", "ง"], ["ผ", "ป", "แ", "อ", "ิ", "ื", "ท", "ม", "ใ", "ฝ"]],
    "physical_shift": [["๐", "\"", "ฎ", "ฑ", "ธ", "ํ", "๊", "ณ", "ฯ", "ญ", "ฐ", ","], ["ฤ", "ฆ", "ฏ", "โ", "ฌ", "็", "๋", "ษ", "ศ", "ซ", "."], ["(", ")", "ฉ", "ฮ", "ฺ", "์", "?", "ฒ", "ฬ", "ฦ"]],
    "rows": [
      ["ๅ", "/", "-", "ภ", "ถ", "ุ", "ึ", "ค", "ต", "จ", "ข", "ช"],
      ["ๆ", "ไ", "ำ", "พ", "ะ", "ั", "ี", "ร", "น", "ย", "บ", "ล"],
      ["ฟ", "ห", "ก", "ด", "เ", "้", "่", "า", "ส", "ว", "ง"],
      [{"k": "shift"}, "ผ", "ป", "แ", "อ", "ิ", "ื", "ท", "ม", "ใ", "ฝ", {"k": "bksp"}],
      [{"k": "space"}, ".", "?", "!"]
    ],
    "shift": [
      ["+", "๑", "๒", "๓", "๔", "ู", "฿", "๕", "๖", "๗", "๘", "๙"],
      ["๐", "\"", "ฎ", "ฑ", "ธ", "ํ", "๊", "ณ", "ฯ", "ญ", "ฐ", ","],
      ["ฤ", "ฆ", "ฏ", "โ", "ฌ", "็", "๋", "ษ", "ศ", "ซ", "."],
      [{"k": "shift"}, "(", ")", "ฉ", "ฮ", "ฺ", "์", "?", "ฒ", "ฬ", "ฦ", {"k": "bksp"}],
      [{"k": "space"}, ".", "?", "!"]
    ] },
  "es": { "name": "Español", "english": "Spanish", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "á", "é", "í", "ó", "ú", "ñ", "ü", "¿", "¡", {"k": "bksp"}]] },
  "fr": { "name": "Français", "english": "French", "upper": true, "accents": true,
    "rows": [["à", "â", "ç", "é", "è", "ê", "ë", "î", "ï", "ô"], [{"k": "shift"}, "ù", "û", "ü", "ÿ", "œ", "æ", "«", "»", {"k": "bksp"}]] },
  "de": { "name": "Deutsch", "english": "German", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "ä", "ö", "ü", "ß", "„", "“", {"k": "bksp"}]] },
  "pt": { "name": "Português", "english": "Portuguese", "upper": true, "accents": true,
    "rows": [["á", "à", "â", "ã", "ç", "é", "ê"], [{"k": "shift"}, "í", "ó", "ô", "õ", "ú", "ü", {"k": "bksp"}]] },
  "it": { "name": "Italiano", "english": "Italian", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "à", "è", "é", "ì", "ò", "ó", "ù", {"k": "bksp"}]] },
  "tr": { "name": "Türkçe", "english": "Turkish", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "ç", "ğ", "ı", "i", "İ", "ö", "ş", "ü", {"k": "bksp"}]] },
  "pl": { "name": "Polski", "english": "Polish", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "ą", "ć", "ę", "ł", "ń", "ó", "ś", "ź", "ż", {"k": "bksp"}]] },
  "cs": { "name": "Čeština", "english": "Czech", "upper": true, "accents": true,
    "rows": [["á", "č", "ď", "é", "ě", "í", "ň", "ó"], [{"k": "shift"}, "ř", "š", "ť", "ú", "ů", "ý", "ž", {"k": "bksp"}]] },
  "sk": { "name": "Slovenčina", "english": "Slovak", "upper": true, "accents": true,
    "rows": [["á", "ä", "č", "ď", "é", "í", "ĺ", "ľ", "ň"], [{"k": "shift"}, "ó", "ô", "ŕ", "š", "ť", "ú", "ý", "ž", {"k": "bksp"}]] },
  "vi": { "name": "Tiếng Việt", "english": "Vietnamese", "upper": true, "accents": true, "compose": "marks",
    "rows": [["ă", "â", "đ", "ê", "ô", "ơ", "ư"], [{"k": "shift"}, "̀", "́", "̉", "̃", "̣", {"k": "bksp"}]] },
  "nl": { "name": "Nederlands", "english": "Dutch", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "é", "ë", "ï", "ö", "ü", "ĳ", {"k": "bksp"}]] },
  "sv": { "name": "Svenska", "english": "Swedish", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "å", "ä", "ö", "é", {"k": "bksp"}]] },
  "da": { "name": "Dansk", "english": "Danish", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "æ", "ø", "å", "é", {"k": "bksp"}]] },
  "no": { "name": "Norsk", "english": "Norwegian", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "æ", "ø", "å", "é", {"k": "bksp"}]] },
  "fi": { "name": "Suomi", "english": "Finnish", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "ä", "ö", "å", "š", "ž", {"k": "bksp"}]] },
  "ro": { "name": "Română", "english": "Romanian", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "ă", "â", "î", "ș", "ț", {"k": "bksp"}]] },
  "hu": { "name": "Magyar", "english": "Hungarian", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "á", "é", "í", "ó", "ö", "ő", "ú", "ü", "ű", {"k": "bksp"}]] },
  "hr": { "name": "Hrvatski", "english": "Croatian", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "č", "ć", "đ", "š", "ž", {"k": "bksp"}]] },
  "eo": { "name": "Esperanto", "english": "Esperanto", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "ĉ", "ĝ", "ĥ", "ĵ", "ŝ", "ŭ", {"k": "bksp"}]] },
  "ca": { "name": "Català", "english": "Catalan", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "à", "è", "é", "í", "ï", "ò", "ó", "ú", "ü", "ç", "l·l", {"k": "bksp"}]] },
  "is": { "name": "Íslenska", "english": "Icelandic", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "á", "ð", "é", "í", "ó", "ú", "ý", "þ", "æ", "ö", {"k": "bksp"}]] },
  "ga": { "name": "Gaeilge", "english": "Irish", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "á", "é", "í", "ó", "ú", {"k": "bksp"}]] },
  "cy": { "name": "Cymraeg", "english": "Welsh", "upper": true, "accents": true,
    "rows": [[{"k": "shift"}, "â", "ê", "î", "ô", "û", "ŵ", "ŷ", "ä", "ë", "ï", "ö", "ü", "ẅ", "ÿ", {"k": "bksp"}]] },
  "sw": { "name": "Kiswahili", "english": "Swahili", "upper": true, "accents": true, "rows": [] },
  "id": { "name": "Bahasa Indonesia", "english": "Indonesian", "upper": true, "accents": true, "rows": [] }
};
