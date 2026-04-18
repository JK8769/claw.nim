## English text-to-phoneme conversion ported from TTS.cpp's built-in phonemizer.
## Uses dictionary lookup + grapheme-to-phoneme rules stored in GGUF format.
## Zero runtime dependencies — all data embedded at compile time via staticRead.
##
## Architecture:
##   1. GraphemeTokenizer: splits words into graphemes (forward max match)
##   2. RuleTree: nested lookup [current][before][after][word] → phoneme
##   3. Dictionary: word → IPA with conditional matching
##   4. Router: handles spaces, numbers, words, acronyms, punctuation

import std/[tables, strutils, sets, unicode, algorithm, parseutils]
import zippy

# ── Embedded data ────────────────────────────────────────────────

const
  GraphemeRaw = staticRead("data/en_graphemes.txt")
  DictRaw = staticRead("data/en_dict.txt")
  RulesGz = staticRead("data/en_rules.txt.gz")

# ── Constants from TTS.cpp/phonemizer.h ──────────────────────────

const
  Alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  Vowels = "aeiouy"
  NumberChars = "0123456789"
  CompatibleNumerics = NumberChars & "., "
  SpaceChars = " \t\x0C\n"
  NoopBreaks = "{}[]():;,\""
  ClauseBreaks = ".!?"

  # Accented character sets (for accent replacement)
  AccentedA = "àãâäáåÀÃÂÄÁÅ"
  AccentedC = "çÇ"
  AccentedE = "èêëéÈÊËÉ"
  AccentedI = "ìîïíÌÎÏÍ"
  AccentedN = "ñÑ"
  AccentedO = "òõôöóøÒÕÔÖÓØ"
  AccentedU = "ùûüúÙÛÜÚ"
  CommonAccented = AccentedA & AccentedC & AccentedE & AccentedI &
                   AccentedN & AccentedO & AccentedU
  WordChars = Alphabet & "." & CommonAccented
  NonClauseWordChars = Alphabet & CommonAccented & "'"

  LetterPhonemes* = {
    'a': "ˈeɪ", 'b': "bˈiː", 'c': "sˈiː", 'd': "dˈiː",
    'e': "ˈiː", 'f': "ˈɛf", 'g': "dʒˈiː", 'h': "ˈeɪtʃ",
    'i': "ˈaɪ", 'j': "dʒˈeɪ", 'k': "kˈeɪ", 'l': "ˈɛl",
    'm': "ˈɛm", 'n': "ˈɛn", 'o': "ˈəʊ", 'p': "pˈiː",
    'q': "kjˈuː", 'r': "ˈɑː", 's': "ˈɛs", 't': "tˈiː",
    'u': "jˈuː", 'v': "vˈiː", 'w': "dˈʌbəljˌuː", 'x': "ˈɛks",
    'y': "wˈaɪ", 'z': "zˈɛd",
  }.toTable

  NumberPhonemes = [
    "zˈiəɹoʊ", "wˈʌn", "tˈuː", "θɹˈiː", "fˈɔːɹ",
    "fˈaɪv", "sˈɪks", "sˈɛvən", "ˈeɪt", "nˈaɪn",
    "tˈɛn", "ɪlˈɛvən", "twˈɛlv", "θˈɜːtiːn", "fˈɔːɹtiːn",
    "fˈɪftiːn", "sˈɪkstiːn", "sˈɛvəntˌiːn", "ˈeɪtiːn", "nˈaɪntiːn",
  ]

  SubHundredPhonemes = [
    "twˈɛnti", "θˈɜːɾi", "fˈɔːɹɾi", "fˈɪfti",
    "sˈɪksti", "sˈɛvənti", "ˈeɪɾi", "nˈaɪnti",
  ]

  Trillion = 1_000_000_000_000'i64
  Billion = 1_000_000_000'i64
  Million = 1_000_000'i64
  Thousand = 1_000'i64
  LargestPronouncable = 999_999_999_999_999'i64

  ContractionPhonemes = {
    "re": "r", "ve": "əv", "ll": "l", "d": "d", "t": "t", "m": "m",
  }.toTable

  Replaceable = {
    "*": "ˈæstɚɹˌɪsk", "+": "plˈʌs", "&": "ˈænd", "%": "pɚsˈɛnt",
    "@": "ˈæt", "#": "hˈæʃ", "$": "dˈɑːlɚ", "~": "tˈɪldə",
    "¢": "sˈɛnts", "£": "pˈaʊnd", "¥": "jˈɛn", "₨": "ɹˈuːpiː",
    "€": "jˈʊɹɹoʊz", "₹": "ɹˈuːpiː", "♯": "ʃˈɑːɹp", "♭": "flˈæt",
    "≈": "ɐpɹˈɑːksɪmətli", "≠": "nˈɑːt ˈiːkwəl tʊ",
    "≤": "lˈɛs ɔːɹ ˈiːkwəl tʊ", "≥": "ɡɹˈeɪɾɚɹ ɔːɹ ˈiːkwəl tʊ",
    ">": "ɡɹˈeɪɾɚ ðɐn", "<": "lˈɛs ðɐn", "=": "ˈiːkwəlz",
    "±": "plˈʌs ɔːɹ mˈaɪnəs", "×": "tˈaɪmz",
    "÷": "dᵻvˈaɪdᵻd bˈaɪ", "℞": "pɹɪskɹˈɪpʃən",
    "№": "nˈuːməˌoʊ", "°": "dᵻɡɹˈiːz", "∴": "ðˈɛɹfɔːɹ",
    "∵": "bɪkˈʌz", "√": "skwˈɛɹ ɹˈuːt", "∛": "kjˈuːb ɹˈuːt",
    "∑": "sˈʌm sˈaɪn", "∂": "dˈɛltə",
    "←": "lˈɛft ˈæɹoʊ", "↑": "ˈʌp ˈæɹoʊ",
    "→": "ɹˈaɪt ˈæɹoʊ", "↓": "dˈaʊn ˈæɹoʊ",
    "−": "mˈaɪnəs", "¶": "pˈæɹəɡɹˌæf", "§": "sˈɛkʃən",
  }.toTable

  RomanNumeralChars = "MDCLXVImdclxvi"
  RomanNumerals = {
    "m": 1000, "mm": 2000, "mmm": 3000,
    "c": 100, "cc": 200, "ccc": 300, "cd": 400, "cm": 900,
    "dc": 600, "dcc": 700, "dccc": 800,
    "x": 10, "xx": 20, "xxx": 30, "xl": 40, "l": 50,
    "lx": 60, "lxx": 70, "lxxx": 80, "xc": 90,
    "i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5,
    "vi": 6, "vii": 7, "viii": 8, "ix": 9,
  }.toTable

# Word lists for acronym detection
const OneLetterWords = ["a", "i"].toHashSet
const TwoLetterWords = [
  "ab","ah","am","an","as","at","aw","ax","ay","be","bo","br",
  "by","do","eh","er","ew","ex","go","ha","he","hi","hm","ho",
  "id","if","in","is","it","la","lo","ma","me","mm","my","na",
  "no","of","oh","oi","on","oo","or","ow","ox","oy","pa","qi",
  "re","sh","so","to","uh","um","un","up","us","we","wo","ya",
  "ye","yo",
].toHashSet
const ThreeLetterWords = [
  "aah","abs","aby","ace","ach","ack","act","add","ado","ads","aft","age",
  "ago","aha","ahi","aid","ail","aim","air","alb","ale","all","alp","alt",
  "ama","amp","and","ant","any","ape","app","apt","arc","are","arf","ark",
  "arm","art","ash","ask","asp","ass","ate","awe","axe","aye","baa","bad",
  "bae","bag","bah","bam","ban","bao","bap","bar","bat","bay","bed","bee",
  "beg","bet","bez","bib","bid","big","bin","bio","bis","bit","biz","boa",
  "bod","bog","boi","boo","bop","bot","bow","box","boy","bra","bro","brr",
  "bub","bud","bug","bum","bun","bur","bus","but","buy","bye","cab","caf",
  "cam","can","cap","car","cat","caw","chi","cig","cis","cly","cob","cod",
  "cog","col","con","coo","cop","cos","cot","cow","cox","coy","cry","cub",
  "cue","cum","cup","cur","cut","cuz","dab","dad","dag","dal","dam","dap",
  "das","daw","day","deb","def","del","den","dep","dew","dib","did","die",
  "dif","dig","dim","din","dip","dis","div","doc","doe","dog","doh","dom",
  "don","dos","dot","dox","dry","dub","dud","due","dug","duh","dum","dun",
  "duo","dup","dur","dye","ear","eat","ebb","eco","eek","eel","egg","ego",
  "elf","elk","elm","emo","emu","end","eon","era","err","est","eve","eww",
  "eye","fab","fad","fae","fag","fah","fam","fan","fap","far","fat","fav",
  "fax","fay","fed","fee","feh","fem","fen","few","fey","fez","fib","fid",
  "fig","fin","fir","fit","fix","flu","fly","fob","foe","fog","foo","fop",
  "for","fox","fro","fry","fub","fun","fur","gab","gad","gag","gal","gam",
  "gah","gap","gas","gay","gee","gel","gem","gen","geo","get","gib","gid","gif",
  "gig","gin","gip","git","goa","gob","god","goo","gor","got","gov","grr",
  "gum","gun","gup","gut","guy","gym","gyp","had","hag","hah","haj","ham",
  "hap","has","hat","haw","hay","heh","hem","hen","her","hes","hew","hex",
  "hey","hic","hid","him","hip","his","hit","hmm","hod","hoe","hog","hop",
  "hot","how","hoy","hub","hue","hug","huh","hum","hun","hup","hut","ice",
  "ich","ick","icy","ids","ifs","ill","imp","ink","inn","int","ion","ire",
  "irk","ism","its","ivy","jab","jam","jap","jar","jaw","jay","jet","jib",
  "jig","jin","job","joe","jog","jot","joy","jug","jut","kat","kaw","kay",
  "ked","keg","key","kid","kin","kit","kob","koi","lab","lac","lad","lag",
  "lam","lap","law","lax","lay","led","leg","lei","lek","let","lev","lex",
  "lib","lid","lie","lip","lit","lob","log","loo","lop","lot","low","lug",
  "luv","lye","mac","mad","mag","mam","man","map","mar","mat","maw","max",
  "may","med","meg","meh","mel","men","met","mew","mib","mid","mig","mil",
  "mix","mmm","mob","mod","mog","mol","mom","mon","moo","mop","mow","mud",
  "mug","mum","mut","nab","nag","nah","nan","nap","nat","naw","nay","nef",
  "neg","net","new","nib","nil","nip","nit","nob","nod","nog","noh","nom",
  "non","noo","nor","not","now","noy","nth","nub","nun","nut","nyx","oaf",
  "oak","oar","oat","oba","obs","oca","odd","ode","off","oft","ohm","oil",
  "oke","old","one","oof","ooh","oom","oop","ops","opt","orb","orc","ore",
  "org","ort","oud","our","out","ova","owe","owl","own","oxy","pad","pah",
  "pal","pan","par","pas","pat","paw","pax","pay","pea","pec","pee","peg",
  "pen","pep","per","pes","pet","pew","phi","pho","pht","pic","pie","pig",
  "pin","pip","pit","pix","ply","pod","poi","pol","poo","pop","pos","pot",
  "pow","pox","pre","pro","pry","psi","pst","pub","pug","puh","pul","pun",
  "pup","pur","pus","put","pwn","pya","pyx","qat","rad","rag","rai","raj",
  "ram","ran","rap","rat","raw","ray","reb","rec","red","ref","reg","rem",
  "res","ret","rex","rez","rho","ria","rib","rid","rig","rim","rin","rip",
  "rob","roc","rod","roe","rom","rot","row","rub","rue","rug","rum","run",
  "rut","rya","rye","sac","sad","sag","sal","sap","sat","saw","sax","say",
  "sea","sec","see","seg","sen","set","sew","sex","she","shh","shy","sib",
  "sic","sig","sim","sin","sip","sir","sis","sit","six","ska","ski","sky",
  "sly","sob","sod","sol","som","son","sop","sot","sou","sow","sox","soy",
  "spa","spy","sty","sub","sue","sum","sun","sup","sus","tab","tad","tag",
  "tai","taj","tan","tao","tap","tar","tat","tau","tav","taw","tax","tch",
  "tea","tec","tee","teg","tel","ten","tet","tex","the","tho","thy","tic","tie",
  "til","tin","tip","tis","tit","tod","toe","ton","too","top","tor","tot",
  "tow","toy","try","tsk","tub","tug","tui","tum","tun","tup","tut","tux",
  "two","ugh","umm","ump","uni","ups","urd","urn","use","uta","ute","utu",
  "uwu","vac","van","var","vas","vat","vav","vax","vee","veg","vet","vex",
  "via","vid","vie","vig","vim","vol","vow","vox","vug","wad","wag","wan",
  "wap","war","was","wat","wax","way","web","wed","wee","wen","wet","wey",
  "who","why","wig","win","wit","wiz","woe","wok","won","woo","wop","wow",
  "wry","wud","wus","yag","yah","yak","yam","yap","yar","yaw","yay","yea",
  "yeh","yen","yep","yes","yet","yew","yin","yip","yok","you","yow","yum",
  "yup","zag","zap","zax","zed","zee","zen","zig","zip","zit","zoo","zzz",
].toHashSet

# ── Types ────────────────────────────────────────────────────────

type
  RuleNode* = ref object
    children: Table[string, RuleNode]
    value: string  ## Phoneme output ("" = no value at this node)

  LookupCode = enum
    lcSuccess = 100
    lcSuccessPartial = 101
    lcFailureUnfound = 200
    lcFailurePhonetic = 201

  DictResponse = object
    code: LookupCode
    value: string
    afterMatch: string
    expectsNumber: bool
    notAtClauseEnd: bool
    notAtClauseStart: bool

  Conditions = object
    hyphenated: bool
    wasAllCapitalized: bool
    wasWord: bool
    wasPunctuatedAcronym: bool
    wasNumber: bool
    beginningOfClause: bool
    lastWordInitial: char

  Corpus = object
    text: string
    pos: int

  EnPhonemizer* = object
    graphemeVocab: HashSet[string]
    graphemeMaxLen: int
    rules: Table[string, RuleNode]  ## current_grapheme → rule tree
    dict: Table[string, seq[DictResponse]]
    smallWords: HashSet[string]

# ── Helpers ──────────────────────────────────────────────────────

proc isAlphabetic(c: char): bool {.inline.} =
  c in {'a'..'z', 'A'..'Z'}

proc isNumeric(c: char): bool {.inline.} =
  c in {'0'..'9'}

proc isRomanNumeral(c: char): bool {.inline.} =
  RomanNumeralChars.contains(c)

proc canBeRomanNumeral(word: string): bool =
  for c in word:
    if not c.isRomanNumeral: return false
  true

proc isAllUpper(word: string): bool =
  for c in word:
    if c.isLowerAscii: return false
  true

proc upperCount(word: string): int =
  for c in word:
    if c.isUpperAscii: inc result

proc toLowerStr(s: string): string =
  result = s.toLowerAscii

proc replaceAccents(word: string): string =
  var i = 0
  while i < word.len:
    let runeLen = word.runeLenAt(i)
    if runeLen > 1:
      let accent = word[i..<i+runeLen]
      if AccentedA.contains(accent): result.add 'a'
      elif AccentedC.contains(accent): result.add 'c'
      elif AccentedE.contains(accent): result.add 'e'
      elif AccentedI.contains(accent): result.add 'i'
      elif AccentedN.contains(accent): result.add 'n'
      elif AccentedO.contains(accent): result.add 'o'
      elif AccentedU.contains(accent): result.add 'u'
      else: result.add accent
    else:
      result.add word[i]
    i += runeLen

# ── Corpus (text scanner) ───────────────────────────────────────

proc initCorpus(text: string): Corpus =
  Corpus(text: text, pos: 0)

proc atEnd(c: Corpus): bool {.inline.} =
  c.pos >= c.text.len

proc runeSize(c: Corpus, offset: int = 0): int =
  ## Get the byte length of the UTF-8 rune at pos+offset.
  let p = c.pos + offset
  if p >= c.text.len: return 0
  let b = c.text[p].uint8
  if b < 0x80: 1
  elif b < 0xE0: 2
  elif b < 0xF0: 3
  else: 4

proc next(c: Corpus, count: int = 1): string =
  ## Peek at the next `count` runes without advancing.
  if c.pos >= c.text.len or count == 0: return ""
  var p = c.pos
  var grabbed = 0
  while grabbed < count and p < c.text.len:
    let sz = Corpus(text: c.text, pos: p).runeSize()
    p += sz
    inc grabbed
  c.text[c.pos..<p]

proc last(c: Corpus, count: int = 1): string =
  ## Peek at the previous `count` runes.
  if c.pos == 0 or count == 0: return ""
  var p = c.pos
  var grabbed = 0
  while grabbed < count and p > 0:
    dec p
    while p > 0 and (c.text[p].uint8 and 0xC0) == 0x80:
      dec p
    inc grabbed
  c.text[p..<c.pos]

proc pop(c: var Corpus, count: int = 1): string =
  result = c.next(count)
  c.pos += result.len

proc after(c: Corpus, byteOffset: int = 1, count: int = 1): string =
  ## Peek `count` runes starting `byteOffset` bytes after current pos.
  let newPos = c.pos + byteOffset
  if newPos >= c.text.len or count == 0: return ""
  var tmp = Corpus(text: c.text, pos: newPos)
  tmp.next(count)

proc sizePop(c: var Corpus, size: int): string =
  let actual = min(size, c.text.len - c.pos)
  result = c.text[c.pos..<c.pos+actual]
  c.pos += actual

proc nextIn(c: Corpus, chars: string, hasAccent: var bool): string =
  ## Peek ahead collecting consecutive runes that appear in `chars`.
  var n = 0
  var running = 0
  var nxt = c.next()
  while nxt != "" and chars.contains(nxt):
    if not hasAccent and CommonAccented.contains(nxt):
      hasAccent = true
    inc n
    running += nxt.len
    nxt = c.after(running)
  c.next(n)

proc nextIn(c: Corpus, chars: string): string =
  var dummy = false
  c.nextIn(chars, dummy)

proc popIn(c: var Corpus, chars: string): string =
  result = c.nextIn(chars)
  c.pos += result.len

proc afterUntil(c: Corpus, byteOffset: int, chars: string): string =
  var n = 0
  var nxt = c.after(byteOffset)
  while nxt != "" and chars.contains(nxt):
    inc n
    nxt = c.after(byteOffset + n)
  c.after(byteOffset, n)

# ── Conditions ───────────────────────────────────────────────────

proc initConditions(): Conditions =
  Conditions(beginningOfClause: true)

proc resetForClauseEnd(f: var Conditions) =
  f.hyphenated = false
  f.wasPunctuatedAcronym = false
  f.beginningOfClause = true
  f.wasNumber = false

proc resetForSpace(f: var Conditions) =
  f.hyphenated = false
  f.wasPunctuatedAcronym = false
  f.wasWord = false

proc updateForWord(f: var Conditions, word: string, allowUpperCheck: bool = true) =
  if allowUpperCheck and not word.isAllUpper:
    f.wasAllCapitalized = false
  f.wasWord = true
  f.beginningOfClause = false
  f.hyphenated = false
  f.wasNumber = false
  if word.len > 0: f.lastWordInitial = word[0]

# ── Grapheme tokenizer ───────────────────────────────────────────

proc splitGraphemes(ph: EnPhonemizer, word: string): seq[string] =
  ## Forward maximum matching to split a word into graphemes.
  var remaining = word
  while remaining.len > 0:
    var token = remaining[0..0]
    for i in 1..<remaining.len:
      let part = remaining[0..i]
      if part notin ph.graphemeVocab:
        break
      token = part
    result.add token
    remaining = remaining[token.len..^1]

# ── Rule tree lookup ─────────────────────────────────────────────

proc lookupRule(node: RuleNode, keys: seq[string], index: int): string =
  if index >= keys.len:
    return node.value
  let key = keys[index]
  # Exact match
  if key in node.children:
    return node.children[key].lookupRule(keys, index + 1)
  # Wildcard suffix match: *suffix
  for k, child in node.children:
    if k.len > 1 and k[0] == '*' and key.endsWith(k[1..^1]):
      return child.lookupRule(keys, index + 1)
  # Wildcard prefix match: prefix*
  for k, child in node.children:
    if k.len > 1 and k[^1] == '*' and key.startsWith(k[0..^2]):
      return child.lookupRule(keys, index + 1)
  return node.value

proc phonemizeGraphemes(ph: EnPhonemizer, word: string): string =
  ## Use grapheme rules to phonemize a word letter by letter.
  let graphemes = ph.splitGraphemes(word.toLowerStr)
  for i, g in graphemes:
    let before = if i > 0: graphemes[i-1] else: "^"
    let after = if i + 1 < graphemes.len: graphemes[i+1] else: "$"
    if g in ph.rules:
      let keys = @[before, after, word.toLowerStr]
      result.add ph.rules[g].lookupRule(keys, 0)

# ── Dictionary lookup ────────────────────────────────────────────

proc isSuccessful(r: DictResponse): bool {.inline.} =
  r.code.int < 200

proc dictLookup(ph: EnPhonemizer, c: Corpus, word: string,
                flags: Conditions): DictResponse =
  if word notin ph.dict:
    return DictResponse(code: lcFailureUnfound)
  let entries = ph.dict[word]
  for entry in entries:
    if entry.code == lcSuccess:
      return entry
    if entry.code == lcSuccessPartial:
      # Check conditions
      if entry.notAtClauseEnd:
        let chunk = c.nextIn(NonClauseWordChars)
        let afterCh = c.after(chunk.len)
        if afterCh == "!" or afterCh == "." or afterCh == "?":
          continue
      let matchAfter = if entry.afterMatch.len > 0:
        c.next(entry.afterMatch.len) == entry.afterMatch
      else: true
      let matchNum = not entry.expectsNumber or flags.wasNumber
      let matchStart = not entry.notAtClauseStart or not flags.beginningOfClause
      if matchAfter and matchNum and matchStart:
        return entry
  # Found entries but none matched conditions → fall through to phonetic
  return DictResponse(code: lcFailurePhonetic)

# ── Number pronunciation ─────────────────────────────────────────

proc buildSubthousand(value: int): string =
  var v = value
  let hundreds = v div 100
  if hundreds > 0:
    result = NumberPhonemes[hundreds] & " " & "hˈʌndɹɪd"
  v = v mod 100
  if v > 0 and v < 20:
    result.add NumberPhonemes[v]
  elif v > 0:
    result.add SubHundredPhonemes[(v div 10) - 2]
    let ones = v mod 10
    if ones > 0:
      result.add " " & NumberPhonemes[ones]

proc buildNumberPhoneme(remainder: int64): string =
  var rem = remainder
  var started = false

  template addUnit(threshold: int64, phoneme: string) =
    if rem > threshold:
      let units = rem div threshold
      rem = rem mod threshold
      let part = buildSubthousand(units.int) & " " & phoneme
      if not started:
        result.add part
        if rem > 0: result.add ","
      elif rem == 0:
        result.add " " & part
      else:
        result.add " " & part & ","
      started = true

  addUnit(Trillion, "tɹˈɪliən")
  addUnit(Billion, "bˈɪliən")
  addUnit(Million, "mˈɪliən")
  addUnit(Thousand, "θˈaʊzənd")

  if rem > 0:
    if started:
      result.add " " & buildSubthousand(rem.int)
    else:
      result.add buildSubthousand(rem.int)

# ── Phonemizer routing ───────────────────────────────────────────

proc handleSpace(ph: EnPhonemizer, c: var Corpus, output: var string,
                 flags: var Conditions): bool =
  flags.resetForSpace()
  discard c.popIn(SpaceChars)
  if output.len > 0 and output[^1] != ' ':
    output.add ' '
  true

proc appendNumericSeries(ph: EnPhonemizer, series: string, output: var string,
                         flags: var Conditions) =
  if flags.wasWord and output.len > 0 and output[^1] != ' ' and not flags.hyphenated:
    output.add ' '
  for i, ch in series:
    let num = ch.ord - '0'.ord
    output.add NumberPhonemes[num]
    if i + 1 < series.len:
      output.add ' '
  if series.len > 0:
    flags.updateForWord(series)
    flags.wasNumber = true

proc handleNumericSeries(ph: EnPhonemizer, c: var Corpus, output: var string,
                         flags: var Conditions): bool =
  let series = c.popIn(NumberChars)
  ph.appendNumericSeries(series, output, flags)
  true

proc handleNumeric(ph: EnPhonemizer, c: var Corpus, output: var string,
                   flags: var Conditions): bool =
  let number = c.nextIn(CompatibleNumerics)
  let stripped = number.strip(chars = {',', '.', ' '})

  # Parse number format (comma/period/space separators)
  var largeSep = '\0'
  var decSep = '\0'
  var lastBreak = '\0'
  var invalidFormat = false
  var countSinceBreak = 0
  var built = ""

  for ch in stripped:
    if ch.isNumeric:
      built.add ch
      inc countSinceBreak
    elif lastBreak == '\0':
      if countSinceBreak > 3:
        decSep = ch
      lastBreak = ch
      built.add ch
      countSinceBreak = 0
    elif ch != lastBreak:
      if ch == ' ':
        break
      elif countSinceBreak == 3 and decSep == '\0':
        if largeSep == '\0':
          largeSep = lastBreak
        decSep = ch
        built.add ch
        countSinceBreak = 0
        lastBreak = ch
      elif countSinceBreak != 3:
        if largeSep != '\0':
          invalidFormat = true
        break
      else:
        break
    elif ch == lastBreak:
      if decSep != '\0':
        break
      elif countSinceBreak != 3:
        invalidFormat = true
        break
      else:
        largeSep = ch
        built.add ch
        countSinceBreak = 0

  if not invalidFormat:
    if largeSep != '\0' and decSep == '\0' and countSinceBreak != 3:
      invalidFormat = true
    elif countSinceBreak == 3 and lastBreak != '\0' and decSep == '\0' and largeSep == '\0':
      largeSep = lastBreak
    elif countSinceBreak != 3 and lastBreak != '\0' and decSep == '\0' and largeSep == '\0':
      decSep = lastBreak

  if invalidFormat:
    return ph.handleNumericSeries(c, output, flags)

  if largeSep != '\0':
    built = built.replace($largeSep, "")
  if decSep == ',':
    built = built.replace(',', '.')

  var value: int64
  try:
    value = parseBiggestInt(built)
  except ValueError:
    return ph.handleNumericSeries(c, output, flags)

  if value >= LargestPronouncable:
    return ph.handleNumericSeries(c, output, flags)

  discard c.sizePop(built.len)

  let nout = buildNumberPhoneme(value)
  if nout.len > 0:
    if flags.wasWord and output.len > 0 and output[^1] != ' ' and not flags.hyphenated:
      output.add ' '
    output.add nout
    flags.updateForWord(built)
    flags.wasNumber = true

  if decSep != '\0':
    let parts = built.split(decSep)
    if parts.len > 1 and parts[1].len > 0:
      output.add " pˈɔɪnt "
      ph.appendNumericSeries(parts[1], output, flags)
  true

proc isAcronymLike(ph: EnPhonemizer, c: Corpus, word: string,
                   flags: var Conditions): bool =
  if '.' in word:
    for part in word.split('.'):
      if part.len == 0: return false
      if part.len > 1:
        if part.len > 2 or not (part[0].isUpperAscii and part[1].isLowerAscii):
          return false
    return true
  elif word.len < 4:
    return word.toLowerStr notin ph.smallWords
  elif word.isAllUpper:
    if flags.wasAllCapitalized or c.afterUntil(word.len + 1, " ").isAllUpper:
      flags.wasAllCapitalized = true
      return false
    return true
  elif not word.isAllUpper and word.upperCount > word.len div 2:
    return true
  false

proc handleAcronym(ph: EnPhonemizer, c: var Corpus, word: string,
                   output: var string, flags: var Conditions): bool =
  var ipa = ""
  for ch in word:
    if ch == '.':
      flags.wasPunctuatedAcronym = true
      continue
    let lower = ch.toLowerAscii
    if lower in LetterPhonemes:
      ipa.add LetterPhonemes[lower]
  discard c.sizePop(word.len)
  if flags.wasWord and output.len > 0 and output[^1] != ' ' and not flags.hyphenated:
    output.add ' '
  output.add ipa
  flags.updateForWord(word, allowUpperCheck = false)
  true

proc dictBase(ph: EnPhonemizer, base: string): string =
  ## Look up base form in dict only.
  if base in ph.dict:
    let r = ph.dict[base][0]
    if r.code == lcSuccess: return r.value
  return ""

proc trySuffixFallback(ph: EnPhonemizer, word: string): string =
  ## Try stripping common English suffixes and phonemizing the base form.
  ## For -ies: tries dict first, then grapheme rules on the base (since the
  ## base is a real word and grapheme rules work better on base forms).
  ## For other suffixes: dict lookup only (grapheme too unreliable).
  let w = word.toLowerStr
  # -ies → base+"y" (cry→cries) or base+"ie" (lie→lies) + /z/
  if w.len > 3 and w.endsWith("ies"):
    # Dict: try both forms
    let dy = ph.dictBase(w[0 ..< w.len - 3] & "y")
    if dy.len > 0: return dy & "z"
    let die = ph.dictBase(w[0 ..< w.len - 1])
    if die.len > 0: return die & "z"
    # Grapheme fallback: base+"ie" first (movie, lie), then base+"y" (cry, fly)
    let gie = ph.phonemizeGraphemes(w[0 ..< w.len - 1])
    if gie.len > 0: return gie & "z"
    let gy = ph.phonemizeGraphemes(w[0 ..< w.len - 3] & "y")
    if gy.len > 0: return gy & "z"
  # -ied → base+"y" (cry→cried) or base+"ie" (die→died) + /d/
  if w.len > 4 and w.endsWith("ied"):
    let by = ph.dictBase(w[0 ..< w.len - 3] & "y")  # "cry" from "cried"
    if by.len > 0: return by & "d"
    let bie = ph.dictBase(w[0 ..< w.len - 1])  # "die" from "died"
    if bie.len > 0: return bie & "d"
  # -ed → base + /d/ (dict first, then grapheme)
  if w.len > 4 and w.endsWith("ed"):
    let base = w[0 ..< w.len - 2]
    let b = ph.dictBase(base)
    if b.len > 0: return b & "d"
    let b2 = ph.dictBase(w[0 ..< w.len - 1])  # "lied" → "lie"
    if b2.len > 0: return b2 & "d"
    # Grapheme fallback: try both base (turn) and base+"e" (urge),
    # pick whichever has a primary stress mark (better phonemization)
    let gb = ph.phonemizeGraphemes(w[0 ..< w.len - 2])
    let ge = ph.phonemizeGraphemes(w[0 ..< w.len - 1])
    let gbStress = "ˈ" in gb
    let geStress = "ˈ" in ge
    if gbStress and not geStress: return gb & "d"
    elif geStress and not gbStress: return ge & "d"
    elif gb.len >= ge.len and gb.len > 0: return gb & "d"
    elif ge.len > 0: return ge & "d"
  # -ing → base + /ɪŋ/ (dict first, then grapheme on base+"e")
  if w.len > 5 and w.endsWith("ing"):
    let b = ph.dictBase(w[0 ..< w.len - 3])
    if b.len > 0: return b & "ɪŋ"
    let b2 = ph.dictBase(w[0 ..< w.len - 3] & "e")
    if b2.len > 0: return b2 & "ɪŋ"
    # Grapheme fallback: base+"e" (dominate→dominating), then base
    let ge = ph.phonemizeGraphemes(w[0 ..< w.len - 3] & "e")
    if ge.len > 0: return ge & "ɪŋ"
    let gb = ph.phonemizeGraphemes(w[0 ..< w.len - 3])
    if gb.len > 0: return gb & "ɪŋ"
  # -es → base + /ɪz/
  if w.len > 3 and w.endsWith("es"):
    let b = ph.dictBase(w[0 ..< w.len - 2])
    if b.len > 0: return b & "ɪz"
  # -s → base + /z/ (dict only — grapheme fallback too risky,
  # many non-plural words end in -s: this, his, bus, focus, etc.)
  if w.len > 2 and w.endsWith("s") and not w.endsWith("ss"):
    let b = ph.dictBase(w[0 ..< w.len - 1])
    if b.len > 0: return b & "z"
  return ""

proc collapseRepeats(word: string): string =
  ## Collapse runs of 3+ identical chars to find the base word.
  ## "pleeeease" → "please", "pffft" → "pfft", "sooooo" → "so"
  ## Tries collapsing to 2 first, then to 1.
  result = ""
  var i = 0
  while i < word.len:
    let ch = word[i]
    var runLen = 1
    while i + runLen < word.len and word[i + runLen] == ch: inc runLen
    if runLen >= 3:
      result.add ch  # collapse to 1
    else:
      for j in 0..<runLen: result.add ch
    i += runLen

proc collapseRepeats2(word: string): string =
  ## Collapse runs of 3+ identical chars to 2.
  result = ""
  var i = 0
  while i < word.len:
    let ch = word[i]
    var runLen = 1
    while i + runLen < word.len and word[i + runLen] == ch: inc runLen
    let keep = if runLen >= 3: 2 else: runLen
    for j in 0..<keep: result.add ch
    i += runLen

proc hasRepeats(word: string): bool =
  for i in 0..<word.len - 2:
    if word[i] == word[i+1] and word[i+1] == word[i+2]: return true

proc handlePhonetic(ph: EnPhonemizer, c: var Corpus, word: string,
                    output: var string, flags: var Conditions,
                    extraBytes: int = 0): bool =
  if flags.wasWord and output.len > 0 and output[^1] != ' ' and not flags.hyphenated:
    output.add ' '
  # Try suffix-stripping fallback before grapheme rules
  let suffixed = ph.trySuffixFallback(word)
  if suffixed.len > 0:
    output.add suffixed
  elif word.hasRepeats:
    # Stretched word (pleeeease, pffft): try collapsed forms in dict.
    # If not in dict, fall through to grapheme on original word
    # (grapheme handles stretching naturally: sooooo → sˈoʊuːuː)
    # Only try dict lookup on collapsed forms >= 4 chars.
    # Short base words (so, no, see) should keep grapheme stretching.
    let c2 = word.collapseRepeats2.toLowerStr  # 3+→2
    let c1 = word.collapseRepeats.toLowerStr    # 3+→1
    var found = false
    if c2.len >= 4:
      let d2 = ph.dictBase(c2)
      if d2.len > 0: output.add d2; found = true
    if not found and c1.len >= 4:
      let d1 = ph.dictBase(c1)
      if d1.len > 0: output.add d1; found = true
    if not found:
      output.add ph.phonemizeGraphemes(word)
  else:
    output.add ph.phonemizeGraphemes(word)
  discard c.sizePop(word.len + extraBytes)
  flags.updateForWord(word)
  true

proc handleRomanNumeral(ph: EnPhonemizer, c: var Corpus, output: var string,
                        flags: var Conditions): bool =
  var total = 0
  var lastValue = 0
  var running = ""
  var nxt = c.next().toLowerStr
  while nxt.len > 0 and nxt[0].isRomanNumeral:
    var found = false
    for sz in countdown(4, 1):
      let chunk = c.after(running.len, sz).toLowerStr
      if chunk in RomanNumerals:
        let fv = RomanNumerals[chunk]
        if total == 0 or lastValue > fv:
          total += fv
          lastValue = fv
          running.add chunk
          found = true
          break
    if not found: return false
    nxt = c.after(running.len).toLowerStr

  let nout = buildNumberPhoneme(total.int64)
  if flags.wasWord and output.len > 0 and output[^1] != ' ' and not flags.hyphenated:
    output.add ' '
  output.add nout
  discard c.sizePop(running.len)
  flags.updateForWord(running, allowUpperCheck = false)
  flags.wasNumber = true
  true

proc handlePossessionPlural(ph: EnPhonemizer, c: var Corpus, output: var string,
                            flags: var Conditions): bool =
  if c.next(2) == "'s":
    let prev = c.last().toLowerStr
    if prev.len > 0 and prev[0] in {'a','e','i','o','u','y'}:
      output.add "z"
    elif prev == "s" or prev == "z":
      output.add "ᵻz"
    elif prev.len > 0 and prev[0].isAlphabetic:
      output.add "s"
    else:
      output.add "ˈɛs"
    discard c.pop(2)
  else:
    discard c.pop()
  true

proc handleContraction(ph: EnPhonemizer, c: var Corpus, output: var string,
                       flags: var Conditions): bool =
  discard c.pop()  # pop the apostrophe
  let nxt = c.nextIn(Alphabet).toLowerStr
  if nxt in ContractionPhonemes:
    output.add ContractionPhonemes[nxt]
    discard c.popIn(Alphabet)
  true

proc processWord(ph: EnPhonemizer, c: var Corpus, output: var string,
                 word: string, flags: var Conditions, hasAccent: bool = false): bool

proc handlePunctuation(ph: EnPhonemizer, c: var Corpus, nxt: string,
                       output: var string, flags: var Conditions): bool =
  let prev = c.last()
  let afterCh = c.after()

  if nxt[0] == '.':
    if flags.wasPunctuatedAcronym:
      flags.wasPunctuatedAcronym = false
      output.add nxt
      discard c.pop()
      if c.after(1, 2) == "'s":
        return ph.handlePossessionPlural(c, output, flags)
      return true
    let chunk = c.nextIn(".")
    output.add chunk
    discard c.sizePop(chunk.len)
    return true
  elif nxt == "'":
    if flags.wasWord and (afterCh == "s" or (afterCh.len > 0 and not afterCh[0].isAlphabetic)):
      return ph.handlePossessionPlural(c, output, flags)
    elif flags.wasWord:
      let afterStr = afterCh
      let after2 = c.after(nxt.len, 2)
      if afterStr in ContractionPhonemes or after2 in ContractionPhonemes:
        return ph.handleContraction(c, output, flags)
    discard c.pop()
    return true
  elif nxt[0] == '-':
    if prev == " " and afterCh == " ":
      discard c.pop(2)
      flags.resetForSpace()
      return true
    elif afterCh.len > 0 and afterCh[0] == '-':
      discard c.pop(2)
      output.add ' '
      flags.resetForSpace()
      return true
    elif not flags.beginningOfClause and flags.wasWord and
         afterCh.len > 0 and afterCh[0].isAlphabetic:
      flags.hyphenated = true
      discard c.pop()
      return true
    else:
      discard c.pop()
      return true
  elif ClauseBreaks.contains(nxt):
    output.add nxt
    flags.resetForClauseEnd()
    discard c.pop()
    return true
  elif NoopBreaks.contains(nxt):
    output.add nxt
    discard c.pop()
    return true
  elif nxt in Replaceable:
    if flags.wasWord and output.len > 0 and output[^1] != ' ' and not flags.hyphenated:
      output.add ' '
    output.add Replaceable[nxt]
    flags.updateForWord(nxt)
    discard c.pop()
    return true
  elif nxt == "\xE2\x80\xA6":  # ellipsis U+2026
    # Output "… " marker — synthesizeSentence splits on this
    # and inserts 11x silence (550ms). Token never reaches model.
    output.add "… "
    flags.resetForClauseEnd()
    discard c.pop()
    return true
  elif nxt == "\xE2\x80\x94":  # em-dash U+2014
    discard c.pop()
    if flags.wasWord:
      # Skip optional space after em-dash
      var afterCh = c.next()
      if afterCh == " ": afterCh = c.after(1)
      if afterCh.len > 0 and afterCh[0].isAlphaAscii and output.len > 0:
        # Stutter pattern (I—I've): only strip when next word starts with
        # same letter as previous word (same initial sound repeating)
        let prevInitial = flags.lastWordInitial
        if prevInitial != '\0' and prevInitial.toLowerAscii == afterCh[0].toLowerAscii:
          var i = output.len - 1
          while i > 0 and output[i] != ' ': dec i
          if i > 0: output.setLen(i + 1)
          else: output.setLen(0)
        else:
          # Not a stutter — output em-dash token for pause system
          output.add "— "
    return true
  else:
    discard c.pop()
    return true

proc handleWord(ph: EnPhonemizer, c: var Corpus, output: var string,
                flags: var Conditions): bool =
  var hasAccent = false
  var word = c.nextIn(WordChars, hasAccent)
  while word.len > 0 and word[^1] == '.':
    word = word[0..^2]
  ph.processWord(c, output, word, flags, hasAccent)

proc processWord(ph: EnPhonemizer, c: var Corpus, output: var string,
                 word: string, flags: var Conditions, hasAccent: bool = false): bool =
  var response: DictResponse
  var extraBytes = 0
  var w = word

  if hasAccent:
    response = ph.dictLookup(c, w, flags)
    if not response.isSuccessful:
      let origLen = w.len
      w = w.replaceAccents
      extraBytes = origLen - w.len
      response = ph.dictLookup(c, w, flags)
  else:
    response = ph.dictLookup(c, w, flags)

  # Case-insensitive fallback for capitalized words (Gah → gah)
  if not response.isSuccessful and w.len > 1 and w[0].isUpperAscii:
    response = ph.dictLookup(c, w.toLowerAscii, flags)

  if response.isSuccessful:
    if flags.wasWord and output.len > 0 and output[^1] != ' ' and not flags.hyphenated:
      output.add ' '
    flags.updateForWord(w)
    if response.code == lcSuccessPartial:
      let fullWord = w & response.afterMatch
      output.add response.value
      discard c.sizePop(fullWord.len + extraBytes)
    else:
      output.add response.value
      discard c.sizePop(w.len + extraBytes)
    return true
  elif w.len > 1 and w.toLowerStr notin ph.smallWords and
       w.canBeRomanNumeral and w.isAllUpper and
       ph.handleRomanNumeral(c, output, flags):
    return true
  elif w.len == 1 and c.after(w.len) == "-":
    # Stutter pattern (l-look, d-do): skip the first letter entirely.
    # The hyphen pause gives hesitation, the word itself starts with the sound.
    discard c.sizePop(w.len + extraBytes)
    flags.updateForWord(w)
    return true
  elif ph.isAcronymLike(c, w, flags):
    return ph.handleAcronym(c, w, output, flags)
  elif '.' in w:
    var partHasAccent = false
    let wordPart = c.nextIn(Alphabet & CommonAccented, partHasAccent)
    discard ph.processWord(c, output, wordPart, flags, partHasAccent)
    discard ph.handlePunctuation(c, ".", output, flags)
    output.add ' '
    flags.resetForSpace()
    return true
  else:
    return ph.handlePhonetic(c, w, output, flags, extraBytes)

proc route(ph: EnPhonemizer, c: var Corpus, output: var string,
           flags: var Conditions): bool =
  let nxt = c.next()
  if nxt == "": return false
  if SpaceChars.contains(nxt):
    return ph.handleSpace(c, output, flags)
  elif nxt[0].isNumeric:
    return ph.handleNumeric(c, output, flags)
  elif nxt[0].isAlphabetic:
    return ph.handleWord(c, output, flags)
  else:
    return ph.handlePunctuation(c, nxt, output, flags)

# ── Public API ───────────────────────────────────────────────────

proc joinSyllableHyphens(text: string): string =
  ## Join syllable-broken words (ev-ery-one's, at-TEN-TION, ex-CUSE)
  ## back into single words. Preserve stutter hyphens (d-do, l-look)
  ## where a single letter repeats. Lowercases emphasis caps when joining
  ## to prevent acronym detection (exCUSE → excuse).
  result = newStringOfCap(text.len)
  var i = 0
  var inSyllableJoin = false  # true when we just dropped a hyphen
  while i < text.len:
    if text[i] == '-' and i > 0 and i + 1 < text.len and
       text[i-1].isAlphaAscii and text[i+1].isAlphaAscii:
      var wordStart = i - 1
      while wordStart > 0 and text[wordStart-1].isAlphaAscii: dec wordStart
      let before = text[wordStart..<i]
      if before.len == 1 and before[0].toLowerAscii == text[i+1].toLowerAscii:
        result.add '-'  # keep stutter hyphen
        inSyllableJoin = false
      else:
        # Syllable break — drop hyphen, lowercase the part before if joining
        if not inSyllableJoin:
          # Lowercase the already-added part before this hyphen
          for j in countup(result.len - before.len, result.len - 1):
            if j >= 0: result[j] = result[j].toLowerAscii
        inSyllableJoin = true
    else:
      if inSyllableJoin and text[i].isAlphaAscii:
        result.add text[i].toLowerAscii
      else:
        result.add text[i]
        if not text[i].isAlphaAscii:
          inSyllableJoin = false
    inc i

proc textToPhonemes*(ph: EnPhonemizer, text: string): string =
  let normalized = joinSyllableHyphens(text)
  var c = initCorpus(normalized)
  var flags = initConditions()
  while ph.route(c, result, flags):
    discard

# ── Data loading ─────────────────────────────────────────────────

proc parseRuleResponse(value: string, key: string): DictResponse =
  let expectsNumber = key.len > 0 and key[0] == '$'
  let notAtStart = key.len > 0 and key[0] == '#'
  let notAtEnd = key.len > 0 and key[^1] == '#'

  let parts = value.split(':')
  if parts.len > 1:
    result = DictResponse(
      code: lcSuccessPartial,
      value: parts[0],
      afterMatch: parts[1],
      expectsNumber: expectsNumber,
      notAtClauseEnd: notAtEnd,
      notAtClauseStart: notAtStart,
    )
  else:
    result = DictResponse(
      code: lcSuccess,
      value: value,
      expectsNumber: expectsNumber,
      notAtClauseEnd: notAtEnd,
      notAtClauseStart: notAtStart,
    )

proc newEnPhonemizer*(): EnPhonemizer =
  ## Create English phonemizer, loading all data from embedded resources.

  # Load grapheme vocabulary
  var vocab: HashSet[string]
  var maxLen = 0
  for line in GraphemeRaw.splitLines:
    let g = line.strip
    if g.len > 0:
      vocab.incl g
      if g.len > maxLen: maxLen = g.len
  result.graphemeVocab = vocab
  result.graphemeMaxLen = maxLen

  # Load dictionary
  for line in DictRaw.splitLines:
    let parts = line.strip.split('\t', 1)
    if parts.len < 2: continue
    var key = parts[0]
    let values = parts[1]
    var entries: seq[DictResponse]
    for val in values.split(','):
      entries.add parseRuleResponse(val, key)
    # Strip special prefix/suffix markers from key
    if key.len > 0 and (key[0] == '$' or key[0] == '#'):
      key = key[1..^1]
    if key.len > 0 and key[^1] == '#':
      key = key[0..^2]
    result.dict[key] = entries

  # Load rules (gzip compressed)
  let rulesText = uncompress(RulesGz, dfGzip)
  for line in rulesText.splitLines:
    let parts = line.split('\t', 1)
    if parts.len < 2: continue
    let keyPath = parts[0]
    let phoneme = parts[1]
    let keys = keyPath.split('.')

    # keys[0] = current grapheme, keys[1..] = context path
    let grapheme = keys[0]
    if grapheme notin result.rules:
      result.rules[grapheme] = RuleNode()

    var node = result.rules[grapheme]
    for i in 1..<keys.len:
      if keys[i] notin node.children:
        node.children[keys[i]] = RuleNode()
      node = node.children[keys[i]]
    node.value = phoneme

    # Set default value at grapheme root if this is a depth-0 rule
    if keys.len == 1:
      result.rules[grapheme].value = phoneme

  # Add interjections/onomatopoeia not covered by GGUF dictionary
  const ExtraDict: array[40, (string, string)] = [
    # Interjections/onomatopoeia
    ("tch", "ts"), ("tsk", "tsk"), ("gah", "ɡɑː"), ("bah", "bɑː"),
    ("meh", "mˈɛ"), ("heh", "hˈɛ"), ("pfft", "pft"), ("shh", "ʃː"),
    ("hmm", "hˈm"), ("grr", "ɡɹː"), ("brr", "bɹː"),
    # Common words with wrong grapheme/dict phonemes
    ("excuse", "ɪkskjˈuːz"), ("attention", "ɐtˈɛnʃən"),
    ("uh", "ˈʌ"), ("ahem", "əhˈɛm"),
    ("gonna", "ɡˈɑːnə"), ("wanna", "wˈɑːnə"),
    ("shoulder", "ʃˈoʊldɚ"), ("dominate", "dˈɑːmɪneɪt"),
    ("dominating", "dˈɑːmɪneɪtɪŋ"), ("guys", "ɡˈaɪz"),
    ("loved", "lˈʌvd"), ("prepared", "pɹɪpˈɛɹd"),
    ("urged", "ˈɜːdʒd"), ("buried", "bˈɛɹid"),
    ("launched", "lˈɔːntʃt"), ("please", "plˈiːz"),
    ("pulled", "pˈʊld"), ("never", "nˈɛvɚ"),
    # -y base forms for correct -ies/-ied suffix stripping
    ("cry", "kɹˈaɪ"), ("fly", "flˈaɪ"), ("try", "tɹˈaɪ"), ("fry", "fɹˈaɪ"),
    ("spy", "spˈaɪ"), ("dry", "dɹˈaɪ"), ("pry", "pɹˈaɪ"),
    ("shy", "ʃˈaɪ"), ("sly", "slˈaɪ"), ("ply", "plˈaɪ"),
    ("sky", "skˈaɪ"),
  ]
  for (word, ipa) in ExtraDict:
    result.dict[word] = @[DictResponse(code: lcSuccess, value: ipa)]

  # Build small words set
  result.smallWords = OneLetterWords + TwoLetterWords + ThreeLetterWords

# ── Smoke test ───────────────────────────────────────────────────

when isMainModule:
  import std/[times, os]

  let ph = newEnPhonemizer()

  if paramCount() >= 1:
    let text = commandLineParams().join(" ")
    echo ph.textToPhonemes(text)
    quit(0)

  echo "Loading English phonemizer..."
  echo "  Graphemes: ", ph.graphemeVocab.len
  echo "  Rules (top-level): ", ph.rules.len
  echo "  Dictionary: ", ph.dict.len

  let tests = [
    "Hello world",
    "The quick brown fox jumps over the lazy dog.",
    "I can't believe it's not butter!",
    "She said, \"Don't go!\"",
    "The price is $42.99",
    "NASA launched Apollo 11 in 1969.",
    "Dr. Smith's office is on 5th Ave.",
    "It's 3:30 PM.",
    "100,000 people attended the event.",
    "iPhone",
    "Python",
    "ChatGPT",
  ]

  echo "\nPhoneme tests:"
  for text in tests:
    let t2 = cpuTime()
    let phonemes = ph.textToPhonemes(text)
    let t3 = cpuTime()
    echo "  \"", text, "\""
    echo "    → ", phonemes
    echo "    (", formatFloat((t3 - t2) * 1000, ffDecimal, 2), "ms)"




