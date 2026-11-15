class_name Wallet
extends Node
## The player's money: balance, earn / spend, persisted to its own file on every change (`Wallet.path`), plus
## small persisted counters for game systems (`get_stat` / `set_stat`, e.g. how many echo courses were bought).
## `Wallet.format(amount)` is the one way to print an amount: the currency sign is a capital R with a vertical
## bar through it, like the dollar's S. No Unicode character draws that, so the sign is a private-use
## character followed by "R": its glyph (the bar, zero advance, drawn forward over the R) comes from a tiny
## procedural bitmap font added as a fallback of the default theme font: it works in every Label, Button and
## RichTextLabel, scales with the font size and needs no asset.

signal changed(balance: int, delta: int, reason: String)  ## After every earn / spend (delta < 0 for spending).

const BAR_CHAR := 0xE000                       ## Private-use code point carrying the bar glyph.
const SIGN := "\uE000R"                       ## The currency sign as text: the bar glyph, then the R.
const SECTION := "wallet"
const GLYPH_SIZE := 64                         ## Bitmap size of the bar glyph (scaled to any font size).

static var path := "user://wallet.cfg"         ## The echo test switches this to a scratch file; "" = in memory.
static var _glyph_installed := false

@export var start_balance := 500               ## Balance of a new game (enough for the first echo course).

var balance: int:
	get:
		return _balance

var _balance := 0
var _stats := {}


func _ready() -> void:
	install_glyph()
	load_wallet()


## Adds money (amount > 0) and tells why ("Echo race", "Delivery", ...).
func earn(amount: int, reason := "") -> void:
	if amount <= 0:
		return
	_balance += amount
	_commit(amount, reason)


## Takes money if there is enough; returns false (and changes nothing) otherwise.
func spend(amount: int, reason := "") -> bool:
	if amount < 0 or not can_afford(amount):
		return false
	if amount == 0:
		return true
	_balance -= amount
	_commit(-amount, reason)
	return true


func can_afford(amount: int) -> bool:
	return amount <= _balance


## Persisted integer/float/string counter shared by game systems.
func get_stat(key: String, default: Variant = 0) -> Variant:
	return _stats.get(key, default)


func set_stat(key: String, value: Variant) -> void:
	_stats[key] = value
	save_wallet()


## "R|1,250" (the sign, thousands separated); `signed` prefixes + or − (always, even for 0 it is +).
static func format(amount: int, signed := false) -> String:
	var digits := str(absi(amount))
	var grouped := ""
	while digits.length() > 3:
		grouped = "," + digits.right(3) + grouped
		digits = digits.left(digits.length() - 3)
	grouped = digits + grouped
	var prefix := ""
	if signed:
		prefix = "−" if amount < 0 else "+"
	elif amount < 0:
		prefix = "−"
	return prefix + SIGN + grouped


func load_wallet() -> void:
	_balance = start_balance
	_stats = {}
	if path.is_empty():
		return
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return  # New game: the file is written on the first change.
	_balance = int(cfg.get_value(SECTION, "balance", start_balance))
	var stats: Variant = cfg.get_value(SECTION, "stats", {})
	if stats is Dictionary:
		_stats = stats


func save_wallet() -> void:
	if path.is_empty():
		return
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "balance", _balance)
	cfg.set_value(SECTION, "stats", _stats)
	var err := cfg.save(path)
	if err != OK:
		push_error("Wallet: cannot write %s (%s)" % [path, error_string(err)])


func _commit(delta: int, reason: String) -> void:
	save_wallet()
	changed.emit(_balance, delta, reason)


## Adds the bar glyph (BAR_CHAR) as a fallback of the default theme font. Idempotent; call before any text
## containing SIGN is shaped (Wallet._ready does).
static func install_glyph() -> void:
	if _glyph_installed:
		return
	var base: Font = ThemeDB.get_default_theme().default_font
	if base == null:
		base = ThemeDB.fallback_font
	if base == null:
		return
	_glyph_installed = true
	var em := float(GLYPH_SIZE)
	var advance_r := base.get_char_size("R".unicode_at(0), GLYPH_SIZE).x
	var cap := em * 0.72                         # Cap height of the default (Open Sans) font.
	var overshoot := em * 0.11                   # Bar length above the cap and below the baseline.
	var stem := maxi(roundi(em * 0.075), 2)      # Bar thickness.
	var rim := 2                                 # Dark edge standing in for the label outline.
	var w := stem + rim * 2
	var h := roundi(cap + overshoot * 2.0) + rim * 2
	var img := Image.create_empty(w, h, false, Image.FORMAT_LA8)
	img.fill(Color(0, 0, 0, 0.45))
	img.fill_rect(Rect2i(rim, rim, stem, h - rim * 2), Color(1, 1, 1, 1))
	var font := FontFile.new()
	font.fixed_size = GLYPH_SIZE
	font.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_ENABLED
	font.generate_mipmaps = true
	var sz := Vector2i(GLYPH_SIZE, 0)
	font.set_cache_ascent(0, GLYPH_SIZE, base.get_ascent(GLYPH_SIZE))
	font.set_cache_descent(0, GLYPH_SIZE, base.get_descent(GLYPH_SIZE))
	font.set_texture_image(0, sz, 0, img)
	font.set_glyph_advance(0, GLYPH_SIZE, BAR_CHAR, Vector2.ZERO)
	# Offset from the pen position (before the R) to the glyph's top-left: the R's middle, above the cap.
	font.set_glyph_offset(0, sz, BAR_CHAR, Vector2(advance_r * 0.5 - w * 0.5, -cap - overshoot - rim))
	font.set_glyph_size(0, sz, BAR_CHAR, Vector2(w, h))
	font.set_glyph_uv_rect(0, sz, BAR_CHAR, Rect2(0, 0, w, h))
	font.set_glyph_texture_idx(0, sz, BAR_CHAR, 0)
	var fallbacks := base.fallbacks.duplicate()
	fallbacks.append(font)
	base.fallbacks = fallbacks
