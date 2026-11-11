#==============================================================================
# RayTrace2D v1.0 -- real-time 2D ray traced colored lighting for OneShot
#------------------------------------------------------------------------------
# Loaded by the engine through oneshot.conf:  preloadScript=Mods/RayTrace2D.rb
# Press HOME (or F8) while walking around to open the preset menu.
#
# How it works (all inside the game process -- nothing runs after you quit):
#  * Every light (Niko's sun bulb, lamps, screens, robots, glowing lightmaps)
#    casts rays to every cell of a screen grid. Rays march through the map's
#    solid tiles (walls) -> real hard/soft shadows.
#  * Depth: lights sit at a height above the floor (Lambert falloff), and wall
#    faces only catch light coming from in front of them (south side).
#  * Bounce: lit cells add a little tinted ambient fill (cheap 1-bounce GI).
#  * The light grid is upscaled + GPU blurred and drawn at 2px pixels, so it
#    keeps OneShot's pixel-art look instead of looking smeary.
#  * Two layers: a subtract layer (darkness/shadow) and an additive layer
#    (colored glow).
# Settings are saved in Mods/RayTrace2D.cfg; errors go to Mods/RayTrace2D.log.
# If anything ever breaks, the mod switches itself off instead of crashing.
#==============================================================================

module RT2D
  VERSION  = "1.0"
  DIR      = $RT2D_DIR || "Mods"   # set by the loader (shared folder for every game copy)
  CFG      = DIR + "/RayTrace2D.cfg"
  LOG      = DIR + "/RayTrace2D.log"
  SELFTEST = DIR + "/selftest.flag"
  KEY_HOME = 74      # SDL scancodes
  KEY_F8   = 65
  STEP     = 12.0    # ray march step in pixels
  LIGHT_H  = 40.0    # light height above the floor (depth / Lambert term)
  LIGHT_H2 = LIGHT_H * LIGHT_H
  SOFT     = [[0.0, 0.0], [-7.0, -5.0], [7.0, 5.0], [-5.0, 7.0], [5.0, -7.0]]   # area-light samples

  PRESETS = [
    { :name => "Off", :desc => "Vanilla OneShot lighting." },
    { :name => "Cozy (Low)", :desc => "Big soft cells, light on the CPU.",
      :cell => 16, :every => 4, :dark => 0.28, :boost => 0.45, :glow => 0.10, :lights => 4,
      :blur => 2, :samples => 1, :bounce => 0.00, :tint => [1.0, 0.98, 0.95] },
    { :name => "Game Style RT", :contact => 0.28, :desc => "Smooth ray traced shadows, subtle glow.",
      :cell => 8, :every => 2, :dark => 0.32, :boost => 0.60, :glow => 0.12, :lights => 6,
      :blur => 3, :samples => 1, :bounce => 0.08, :tint => [1.0, 0.98, 0.95] },
    { :name => "Ultra RT", :contact => 0.30, :desc => "Soft area shadows + bounce light.",
      :spec => 0.4, :refl => 0.35, :cell => 8, :every => 2, :dark => 0.38, :boost => 0.70, :glow => 0.14, :lights => 8,
      :blur => 4, :samples => 3, :bounce => 0.12, :tint => [1.0, 0.98, 0.95] },
    { :name => "Pixel Raw", :desc => "No blur. Crunchy retro shadows.",
      :hard => true,
      :cell => 8, :every => 2, :dark => 0.32, :boost => 0.60, :glow => 0.12, :lights => 6,
      :blur => 0, :samples => 1, :bounce => 0.00, :tint => [1.0, 0.98, 0.95] },
    { :name => "Neon Dream", :desc => "Rainbow-shifting colored lights.",
      :cell => 8, :every => 2, :dark => 0.36, :boost => 0.70, :glow => 0.25, :lights => 6,
      :blur => 3, :samples => 1, :bounce => 0.10, :tint => [0.95, 1.0, 0.90],
      :neon => true },
    # ---- RTX-inspired presets (techniques modeled on RTX Remix: path-traced
    #      bounce light, many-light sampling, emissive surfaces, temporal
    #      denoising, physically based falloff, filmic HDR tone mapping) ----
    { :name => "RTX Realistic", :contact => 0.38, :desc => "Bounce light, AO, emissives, filmic HDR.",
      :volume => 0.05, :particles => 6, :obj_shadows => 0.38, :caustics => 1.0, 
      :spec => 0.5, :refl => 0.45, :cell => 8, :every => 3, :dark => 0.55, :boost => 0.70, :glow => 0.08, :lights => 16,
      :blur => 3, :samples => 3, :bounce => 0.0, :tint => [1.0, 0.97, 0.92],
      :amb_tint => [0.93, 0.97, 1.08], :phys => true, :gi => 0.9, :gi_rays => 8,
      :ao => 0.35, :emissive => 12, :filmic => true, :exposure => true, :temporal => 0.5 },
    { :name => "RTX Path Traced", :contact => 0.40, :desc => "Max: shadowed bounces, 5-ray soft shadows.",
      :volume => 0.05, :particles => 8, :obj_shadows => 0.38, :caustics => 1.2, 
      :spec => 0.55, :refl => 0.55, :cell => 8, :every => 3, :dark => 0.45, :boost => 0.80, :glow => 0.08, :lights => 16,
      :blur => 4, :samples => 5, :bounce => 0.0, :tint => [1.0, 0.96, 0.90],
      :amb_tint => [0.92, 0.96, 1.10], :phys => true, :gi => 1.0, :gi_rays => 12,
      :gi_shadow => true, :ao => 0.40, :emissive => 16, :filmic => true, :exposure => true,
      :temporal => 0.6 },
    { :name => "Cinematic Soft", :contact => 0.30, :desc => "Eye-friendly: low contrast, warm, calm.",
      :volume => 0.05, :particles => 6, :obj_shadows => 0.38, :caustics => 0.8, 
      :spec => 0.35, :refl => 0.30, :cell => 8, :every => 3, :dark => 0.28, :boost => 0.50, :glow => 0.05, :lights => 14,
      :blur => 4, :samples => 3, :bounce => 0.0, :tint => [1.0, 0.95, 0.88],
      :amb_tint => [0.97, 0.98, 1.03], :phys => true, :gi => 0.6, :gi_rays => 6,
      :ao => 0.25, :emissive => 10, :filmic => true, :exposure => true, :temporal => 0.65 },
    { :name => "HDR Classic", :contact => 0.35, :desc => "2004 HDR look: bloom + eye adaptation.",
      :volume => 0.05, :particles => 6, :obj_shadows => 0.38, :caustics => 1.0, :emissive => 8, 
      :spec => 0.5, :refl => 0.35, :cell => 8, :every => 2, :dark => 0.42, :boost => 0.85, :glow => 0.22, :lights => 6,
      :blur => 3, :samples => 1, :bounce => 0.06, :tint => [1.0, 0.97, 0.90],
      :ao => 0.20, :phys => true, :filmic => true, :exposure => true, :temporal => 0.4 },
    # ---- REAL path tracing: Monte Carlo rays + next-event estimation +
    #      progressive accumulation (see path_trace) ----
    { :name => "Path Tracing", :contact => 0.38, :desc => "Real Monte Carlo GI, 1 bounce, converges.",
      :volume => 0.05, :particles => 6, :obj_shadows => 0.38, :caustics => 1.0, 
      :spec => 0.5, :refl => 0.45, :cell => 8, :every => 3, :dark => 0.6, :boost => 0.75, :glow => 0.06, :lights => 16,
      :blur => 4, :samples => 3, :bounce => 0.0, :tint => [1.0, 0.97, 0.92],
      :amb_tint => [0.94, 0.97, 1.06], :phys => true, :ao => 0.15, :emissive => 12,
      :filmic => true, :exposure => true, :temporal => 0.35,
      :pt => true, :pt_spp => 1, :pt_bounces => 1, :pt_dist => 220.0, :pt_gain => 1.6,
      :pt_accum => 24 },
    { :name => "Path Tracing HQ", :contact => 0.40, :desc => "2 rays/cell, 2 bounces, 5-ray shadows.",
      :volume => 0.05, :particles => 8, :obj_shadows => 0.38, :caustics => 1.2, 
      :spec => 0.55, :refl => 0.55, :cell => 8, :every => 4, :dark => 0.65, :boost => 0.80, :glow => 0.06, :lights => 16,
      :blur => 4, :samples => 5, :bounce => 0.0, :tint => [1.0, 0.97, 0.92],
      :amb_tint => [0.94, 0.97, 1.06], :phys => true, :ao => 0.10, :emissive => 16,
      :filmic => true, :exposure => true, :temporal => 0.35,
      :pt => true, :pt_spp => 2, :pt_bounces => 2, :pt_dist => 260.0, :pt_gain => 1.8,
      :pt_accum => 32 },
    # ---- reflections + everything ----
    { :name => "RT Reflections", :contact => 0.35, :desc => "Mirror floors, water, metal sheen.",
      :volume => 0.05, :particles => 6, :obj_shadows => 0.38, :caustics => 1.2, 
      :cell => 8, :every => 2, :dark => 0.34, :boost => 0.65, :glow => 0.10, :lights => 16,
      :spec => 0.7, :refl => 0.65, :blur => 3, :samples => 1, :bounce => 0.06,
      :tint => [1.0, 0.97, 0.92], :phys => true, :emissive => 12, :ao => 0.20,
      :filmic => true, :exposure => true, :temporal => 0.4 },
    { :name => "ULTIMATE (All RTX)", :contact => 0.42, :desc => "Path tracing+reflections+materials+all.",
      :volume => 0.05, :particles => 8, :obj_shadows => 0.38, 
      :cell => 12, :every => 3, :dark => 0.86, :boost => 0.60, :glow => 0.07, :lights => 20,
      :spec => 0.55, :refl => 0.60, :blur => 4, :samples => 3, :bounce => 0.0,
      :tint => [1.0, 0.97, 0.92], :amb_tint => [0.94, 0.97, 1.06], :phys => true,
      :ao => 0.18, :emissive => 12, :filmic => true, :exposure => true, :temporal => 0.4,
      :pt => true, :pt_spp => 1, :pt_bounces => 1, :pt_dist => 200.0, :pt_gain => 1.3,
      :pt_accum => 32 },
  ]
  DEFAULT_PRESET = 13

  # [regex, color (nil = region color), radius px, intensity]
  # Built from a scan of every event graphic / event name in all 263 maps.
  # Order matters: specific first.
  KEYWORDS = [
    [/window|sunlight|moonlight/,               [0.62, 0.56, 1.0], 280.0, 1.35],
    [/jars_light|jars_new|phosph/,              [0.55, 1.0, 0.95], 110.0, 0.70],
    [/sparkle_blue/,                            [0.55, 0.85, 1.0],  40.0, 0.22],
    [/sparkle_red/,                             [1.0, 0.55, 0.45],  40.0, 0.22],
    [/clover/,                                  [0.50, 1.0, 0.60],  60.0, 0.40],
    [/purp_screens|purp_glitch/,                [0.80, 0.50, 1.0], 100.0, 0.55],
    [/tv_light|tv_screens|tv_static|tv_door|tv_encounter|countdown/, [0.60, 0.80, 1.0], 110.0, 0.65],
    [/terminal|^pc|mines_puzzle_screen|computer|screen|monitor/,     [0.55, 0.80, 1.0], 100.0, 0.60],
    [/powercore/,                               [0.50, 0.80, 1.0], 120.0, 0.80],
    [/fishtank/,                                [0.40, 0.75, 1.0],  90.0, 0.50],
    [/portal_rays|door_portal/,                 [1.0, 0.95, 0.80], 120.0, 0.70],
    [/red_light_puzzle/,                        [1.0, 0.40, 0.30],  80.0, 0.60],
    [/lamplighter_working|lamplighter_helping|lampbot/, [1.0, 0.75, 0.45], 140.0, 0.80],
    [/sun|bulb/,                                [1.0, 0.85, 0.50], 150.0, 1.00],
    [/lamp|lantern|torch|candle|fire|glow|^light$|light_/, [1.0, 0.78, 0.45], 130.0, 0.90],
    [/firefl/,                                  [0.90, 1.0, 0.50],  60.0, 0.40],
    [/robots_in|robots_out|nursebot|robots$|robot_box|glitch_robot/, nil, 50.0, 0.30],
    [/sign/,                                    [1.0, 0.95, 0.80],  60.0, 0.40],
  ]
  REGION = { "blue" => [0.45, 0.75, 1.0], "green" => [0.50, 1.0, 0.55],
             "red" => [1.0, 0.55, 0.35], "purp" => [0.80, 0.50, 1.0],
             "tower" => [0.90, 0.90, 1.0] }
  OFF_WORDS = /(_off|off$|depowered|eyeclosed|broken|lightmap|overlay)/
  EV_OFF    = /plight|turn on|switch|nopass|map events|leaves the screen|fire action/   # event names that aren't lights

  @preset = DEFAULT_PRESET
  @wasd = true
  @lang_mode = :ru_custom
  RU_CUSTOM = DIR + "/ru_custom.po"
  @stats = false
  @broken = false
  @in_menu = false
  @frame = 0
  @next_refresh = 0
  @extra_every = 0
  @ms = 0.0
  @nlights = 0
  @prev_key = false
  @info = {}
  @map_key = nil
  @key_src = nil

  class << self
    #--------------------------------------------------------------------------
    # Logging / config
    #--------------------------------------------------------------------------
    def log(msg)
      Dir.mkdir(DIR) unless File.directory?(DIR)
      File.open(LOG, "a") { |f| f.puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}") }
    rescue StandardError
    end

    def fail(e)
      @broken = true
      log("ERROR (mod disabled for this session): #{e.class}: #{e.message}\n  " +
          (e.backtrace || [])[0, 8].join("\n  "))
      hide
    rescue StandardError
    end

    def load_cfg
      return unless File.exist?(CFG)
      File.readlines(CFG).each do |line|
        k, v = line.strip.split("=", 2)
        next unless v
        case k
        when "preset" then i = v.to_i; @preset = i if i >= 0 && i < PRESETS.size
        when "stats"  then @stats = (v == "1")
        when "wasd"   then @wasd = (v != "0")
        when "lang"   then @lang_mode = v.to_sym if %w[en ru ru_custom].include?(v)
        end
      end
    rescue StandardError => e
      log("cfg read failed: #{e.message}")
    end

    def save_cfg
      Dir.mkdir(DIR) unless File.directory?(DIR)
      File.open(CFG, "w") do |f|
        f.puts("# RayTrace2D settings (#{PRESETS.each_with_index.map { |p, i| "#{i}=#{p[:name]}" }.join(', ')})")
        f.puts("preset=#{@preset}")
        f.puts("stats=#{@stats ? 1 : 0}")
        f.puts("wasd=#{@wasd == false ? 0 : 1}")
        f.puts("lang=#{@lang_mode || :ru_custom}")
      end
    rescue StandardError => e
      log("cfg write failed: #{e.message}")
    end

    def boot
      if File.exist?(LOG) && File.size(LOG) > 256 * 1024
        File.open(LOG, "w") { |f| f.puts("(log trimmed)") } rescue nil
      end
      load_cfg
      build_ru_custom
      tour_init
      raw_keys
      log("RayTrace2D #{VERSION} loaded. ruby=#{RUBY_VERSION} preset=#{PRESETS[@preset][:name]} " +
          "keys=#{@key_src || 'NONE'} gpu_blur=#{Bitmap.method_defined?(:blur)}")
    end

    #--------------------------------------------------------------------------
    # Keyboard (HOME / F8) via the engine's raw key states
    #--------------------------------------------------------------------------
    # The improved Russian = the game's own Languages/ru.po with our rewritten
    # lines (Mods/ru_custom/*.txt, "#ID <entry>" blocks) swapped in. Built on
    # the player's PC, so no game text ever has to be shipped with the mod.
    def build_ru_custom
      src = "Languages/ru.po"
      pdir = DIR + "/ru_custom"
      return unless File.exist?(src) && File.directory?(pdir)
      parts = Dir.glob(pdir + "/*.txt").sort
      return if parts.empty?
      newest = ([File.mtime(src)] + parts.map { |x| File.mtime(x) }).max
      return if File.exist?(RU_CUSTOM) && File.mtime(RU_CUSTOM) >= newest
      patch = {}
      parts.each do |pf|
        cur = nil
        buf = []
        File.read(pf, :encoding => "UTF-8").split("\n").each do |line|
          line = line.chomp("\r")
          if line =~ /\A#ID (\d+)\s*\z/
            patch[cur] = buf.join("") if cur
            cur = $1.to_i
            buf = []
          elsif cur
            buf << line
          end
        end
        patch[cur] = buf.join("") if cur
      end
      lines = File.read(src, :encoding => "UTF-8").split("\n", -1)
      out = []
      idx = -1
      skipping = false
      lines.each do |line|
        if skipping
          next if line.start_with?('"')
          skipping = false
        end
        idx += 1 if line.start_with?("msgid ")
        if line.start_with?("msgstr ") && (txt = patch[idx])
          out << "msgstr \"" + txt.gsub("\\") { "\\\\" }.gsub('"') { '\\"' } + "\""
          skipping = true
        else
          out << line
        end
      end
      File.open(RU_CUSTOM, "wb") { |f| f.write(out.join("\n")) }
      log("improved Russian built: #{patch.size} rewritten lines")
    rescue StandardError => e
      log("improved Russian build failed: #{e.class}: #{e.message}")
    end

    def raw_keys
      if defined?(MKXP) && MKXP.respond_to?(:raw_key_states)
        @key_src ||= "MKXP.raw_key_states"
        MKXP.raw_key_states
      elsif Input.respond_to?(:raw_key_states)
        @key_src ||= "Input.raw_key_states"
        Input.raw_key_states
      elsif Kernel.respond_to?(:raw_key_states, true)
        @key_src ||= "Kernel#raw_key_states"
        Kernel.send(:raw_key_states)
      end
    rescue StandardError
      nil
    end

    def key?(states, code)
      return false unless states
      v = states.is_a?(String) ? states.getbyte(code) : states[code]
      !!v && v != 0
    end

    KEY_LALT = 226
    KEY_RALT = 230

    def toggle_pressed?
      s = raw_keys
      down = key?(s, KEY_HOME) || key?(s, KEY_F8)
      edge = down && !@prev_key
      @prev_key = down
      edge || alt_tapped?(s)
    end

    # Alt alone (pressed and released with no other key) opens the menu too.
    def alt_tapped?(s)
      return false unless s.is_a?(String)
      alt = key?(s, KEY_LALT) || key?(s, KEY_RALT)
      if alt
        unless @alt_down
          @alt_down = true
          @alt_dirty = false
        end
        # any other key while Alt is held (Enter, Tab, F4...) cancels it
        unless @alt_dirty
          i = 4
          while i < 226
            if s.getbyte(i) != 0
              @alt_dirty = true
              break
            end
            i += 1
          end
        end
        false
      elsif @alt_down
        @alt_down = false
        !@alt_dirty
      else
        false
      end
    end

    #--------------------------------------------------------------------------
    # Per-frame entry point (called from Graphics.update)
    #--------------------------------------------------------------------------
    def map_ready?
      defined?(Scene_Map) && $scene.is_a?(Scene_Map) && $game_map && $game_player &&
        $game_map.data
    end

    def frame
      return if @broken || @in_menu
      if File.exist?(SELFTEST) && !@selftest_done
        @selftest_done = true
        selftest
      end
      test_tour if @tour_on
      pressed = toggle_pressed?
      unless map_ready?
        hide
        return
      end
      if pressed
        begin
          open_menu
        rescue StandardError => e
          # a menu problem must never kill the lighting itself
          log("menu error: #{e.class}: #{e.message}\n  " + (e.backtrace || [])[0, 4].join("\n  "))
        end
      end
      p = PRESETS[@preset]
      if p[:cell].nil?
        hide
        return
      end
      ensure_layers
      key = [$game_map.map_id, $game_map.data.object_id]
      if key != @map_key
        build_solid
        @map_key = key
        @next_refresh = 0
        @prev_acc = nil
        @pt_buf = nil
        @eshadow = nil
        @eshadow_sig = nil
      end
      @frame += 1
      if @frame >= @next_refresh
        t0 = Time.now
        refresh(p)
        dt = (Time.now - t0) * 1000.0
        @ms = @ms * 0.85 + dt * 0.15
        auto_perf
        @next_refresh = @frame + p[:every] + @extra_every
      end
      place_layers
      update_objects(p)
      update_stats(p)
    end

    def auto_perf
      return unless @frame % 40 == 0
      if @ms > 16.0 && @extra_every < 4
        @extra_every += 1
      elsif @ms < 7.0 && @extra_every > 0
        @extra_every -= 1
      end
    end

    #--------------------------------------------------------------------------
    # Map occluders: a tile is solid if it blocks all 4 directions
    #--------------------------------------------------------------------------
    def build_solid
      m = $game_map
      w = m.width
      h = m.height
      data = m.data
      pas = m.passages
      s = "\0" * (w * h)
      y = 0
      while y < h
        x = 0
        while x < w
          2.downto(0) do |layer|
            id = data[x, y, layer]
            next if id.nil? || id == 0
            if (pas[id].to_i & 0x0f) == 0x0f
              s.setbyte(x + y * w, 1)
              break
            end
          end
          x += 1
        end
        y += 1
      end
      @solid = s
      @mw = w
      @mh = h
      build_base
    end

    def solid?(tx, ty)
      return false unless @solid && @mw
      return false if tx < 0 || ty < 0 || tx >= @mw || ty >= @mh
      @solid.getbyte(tx + ty * @mw) == 1
    end

    #--------------------------------------------------------------------------
    # Light sources
    #--------------------------------------------------------------------------
    def bulb?
      has_lightbulb?
    rescue StandardError
      false
    end

    def gather_lights(p, dxp, dyp)
      list = []
      pl = $game_player
      if pl && !pl.transparent
        wx = pl.real_x / 4.0 + 16
        wy = pl.real_y / 4.0 + 6
        if bulb?
          list << [wx, wy, 220.0, 1.0, 0.90, 0.68, 1.10, 0.0, false, false, nil, 6.0]   # the sun: small, bright
        else
          list << [wx, wy - 10.0, 85.0, 1.0, 0.92, 0.55, 0.55, 0.0, false, false, nil, 3.0]   # Niko's glowing eyes
        end
      end
      cx = dxp + 320
      cy = dyp + 240
      others = []
      $game_map.events.each_value do |ev|
        next if ev.transparent || ev.opacity < 20
        next if ev.instance_variable_get(:@erased)
        name = ev.character_name.to_s
        # graphic-less events can still be lights (e.g. the start room's
        # "window light"), but only while one of their pages is active
        next if name.empty? && ev.instance_variable_get(:@page).nil?
        info = light_info(ev, name)
        next unless info
        rad = info[3]
        wx = ev.real_x / 4.0 + 16
        wy = ev.real_y / 4.0 + (name.empty? ? 28 : 12)
        next if wx < dxp - rad || wx > dxp + 640 + rad || wy < dyp - rad || wy > dyp + 480 + rad
        wy = push_out(wx, wy)
        d = (wx - cx) ** 2 + (wy - cy) ** 2
        li = info[4]
        if info[6]
          # a real flame never burns perfectly steady (subtle, slow)
          ph = ev.id * 1.7
          li *= 0.94 + 0.04 * Math.sin(@frame * 0.19 + ph) + 0.02 * Math.sin(@frame * 0.53 + ph * 2.3)
        end
        others << [wx, wy, rad, info[0], info[1], info[2], li, d, false, info[5], nil,
                   info[5] ? 30.0 : (rad >= 120.0 ? 10.0 : 5.0)]
      end
      if p[:particles]
        begin
          ss = $scene.instance_variable_get(:@spriteset)
          if ss && ss.instance_variable_get(:@particles_type) == :fireflies
            layer = ss.instance_variable_get(:@particles)
            parts = layer && layer.instance_variable_get(:@particles)
            if parts
              lit = parts.select { |q| q.opacity > 110 }.sort_by { |q| -q.opacity }[0, p[:particles]]
              lit.each do |q|
                fx = q.x + dxp
                fy = q.y + dyp
                others << [fx, fy, 60.0, 0.80, 1.0, 0.45, 0.50 * q.opacity / 255.0, 0.0, false, false, nil, 2.0]
              end
            end
          end
        rescue StandardError
        end
      end
      if p[:emissive] && @emissive
        em = []
        @emissive.each do |ex, ey, r, g, b, er, ei|
          next if ex < dxp - er || ex > dxp + 640 + er || ey < dyp - er || ey > dyp + 480 + er
          ey2 = push_out(ex, ey)
          em << [ex, ey2, er, r, g, b, ei, (ex - cx) ** 2 + (ey - cy) ** 2, false, false, 1, er * 0.12]
        end
        em.sort_by! { |l| l[7] }
        others.concat(em[0, p[:emissive]])
      end
      others.sort_by! { |l| l[7] }
      list.concat(others)
      list = list[0, p[:lights]]
      if p[:neon]
        list.each_with_index do |l, i|
          r, g, b = hsv((@frame * 2 + i * 70) % 360)
          l[3] = r; l[4] = g; l[5] = b
        end
      end
      list
    end

    # a lamp/window inside a wall tile would be fully blocked: emit from the
    # first open tile in front of it (top-down view: south)
    def push_out(wx, wy)
      tx = (wx / 32.0).floor
      ty = (wy / 32.0).floor
      return wy unless solid?(tx, ty)
      (1..4).each do |k|
        return (ty + k) * 32 + 2.0 unless solid?(tx, ty + k)
      end
      wy
    end

    def light_info(ev, name)
      evname = (ev.instance_variable_get(:@event).name rescue "").to_s
      key = name + "|" + evname
      return @info[key] if @info.key?(key)
      @info[key] = compute_info(name, name.downcase, evname.downcase)
    end

    def compute_info(name, lname, levname)
      return nil if lname =~ OFF_WORDS || levname =~ EV_OFF
      # graphic-less events only count when their NAME says they are a light
      return nil if lname.empty? && levname !~ /window|sunlight|moonlight|lamp|^light$|glow|lightbulb/
      # NOTE: OneShot's Graphics/Lightmaps are "visible in the dark" versions of
      # sprites (bed, niko, jars...), not lamps -- so they are NOT light sources.
      text = lname + " " + levname
      spot = (text =~ /window|sunlight|moonlight/) ? true : false
      flame = (text =~ /lamp|lantern|torch|candle|fire/) ? true : false
      KEYWORDS.each do |rx, color, rad, inten|
        next unless text =~ rx
        color ||= region_color(lname) || [1.0, 0.8, 0.55]
        return [color[0], color[1], color[2], rad, inten, spot, flame]
      end
      nil
    end

    def region_color(lname)
      REGION.each { |k, c| return c if lname.start_with?(k) }
      nil
    end

    def sample_color(bmp)
      r = g = b = ws = 0.0
      w = bmp.width
      h = bmp.height
      sx = [w / 24, 1].max
      sy = [h / 24, 1].max
      y = 0
      while y < h
        x = 0
        while x < w
          c = bmp.get_pixel(x, y)
          wt = (c.alpha / 255.0) * ((c.red + c.green + c.blue) / 765.0)
          r += c.red * wt; g += c.green * wt; b += c.blue * wt; ws += wt
          x += sx
        end
        y += sy
      end
      return [1.0, 0.85, 0.6] if ws < 0.001
      m = [r, g, b].max
      [r / m, g / m, b / m]
    end

    def hsv(h)
      x = 1.0 - ((h / 60.0) % 2 - 1).abs
      case (h / 60).to_i
      when 0 then [1.0, x, 0.2]
      when 1 then [x, 1.0, 0.2]
      when 2 then [0.2, 1.0, x]
      when 3 then [0.2, x, 1.0]
      when 4 then [x, 0.2, 1.0]
      else        [1.0, 0.2, x]
      end
    end

    #--------------------------------------------------------------------------
    # Ray tracing core
    #--------------------------------------------------------------------------
    def trace(sx, sy, ex, ey, ltx, lty, etx, ety)
      dx = ex - sx
      dy = ey - sy
      n = (Math.sqrt(dx * dx + dy * dy) / STEP).to_i
      return true if n < 2
      sol = @solid
      w = @mw
      h = @mh
      inv = 1.0 / n
      k = 1
      while k < n
        t = k * inv
        tx = ((sx + dx * t) / 32.0).floor
        ty = ((sy + dy * t) / 32.0).floor
        if tx >= 0 && ty >= 0 && tx < w && ty < h &&
           (tx != etx || ty != ety) && (tx != ltx || ty != lty) &&
           sol.getbyte(tx + ty * w) == 1
          return false
        end
        k += 1
      end
      true
    end

    # Shadow rays toward points spread ACROSS the light (perpendicular to the
    # ray, scaled by the light's real size). Like a ray tracer sampling an area
    # light: small lights give sharp shadows, big ones soft; and shadows are
    # naturally sharp at the contact point and widen with distance (the
    # penumbra = size * (receiver - blocker) / blocker relation of PCSS).
    AREA = { 2 => [-0.5, 0.5], 3 => [0.0, -0.8, 0.8], 4 => [-0.9, -0.3, 0.3, 0.9],
             5 => [0.0, -0.5, 0.5, -1.0, 1.0] }

    def visibility(wx, wy, cx, cy, ltx, lty, etx, ety, samples, size = 7.0)
      return(trace(wx, wy, cx, cy, ltx, lty, etx, ety) ? 1.0 : 0.0) if samples <= 1
      dx = cx - wx
      dy = cy - wy
      d = Math.sqrt(dx * dx + dy * dy)
      d = 1.0 if d < 1.0
      px = -dy / d * size
      py = dx / d * size
      offs = AREA[samples] || AREA[3]
      hit = 0
      offs.each { |o| hit += 1 if trace(wx + px * o, wy + py * o, cx, cy, ltx, lty, etx, ety) }
      hit.to_f / offs.size
    end

    # Fills ar/ag/ab (gw*gh) with traced light for the grid whose world origin is ox,oy
    def trace_grid(p, ox, oy, gw, gh, lights)
      cell = p[:cell]
      half = cell / 2.0
      samples = p[:samples]
      n = gw * gh
      ar = Array.new(n, 0.0)
      ag = Array.new(n, 0.0)
      ab = Array.new(n, 0.0)
      phys = p[:phys]
      hard = p[:hard]                 # Pixel Raw keeps exact per-cell crunchy shadows
      caus = p[:caustics]
      ct = @frame * 0.03
      # specular (reflections of lights on glossy materials) -> separate HDR buffer
      spec = (p[:spec] && @gloss) ? p[:spec] : nil
      if spec
        xr = Array.new(n, 0.0); xg = Array.new(n, 0.0); xb = Array.new(n, 0.0)
        gls = @gloss; mats = @mat; mw = @mw; mh = @mh
      end
      lights.each do |lt|
        wx, wy, rad, cr, cg, cb, inten, _dist, nosh, spot, lsmp, lsize = lt
        lsize ||= 8.0
        smp = lsmp || samples
        r2 = rad * rad
        inv_r0 = 1.0 / ((rad * 0.3) ** 2)
        i0 = ((wx - rad - ox) / cell).floor; i0 = 0 if i0 < 0
        i1 = ((wx + rad - ox) / cell).ceil;  i1 = gw - 1 if i1 > gw - 1
        j0 = ((wy - rad - oy) / cell).floor; j0 = 0 if j0 < 0
        j1 = ((wy + rad - oy) / cell).ceil;  j1 = gh - 1 if j1 > gh - 1
        ltx = (wx / 32.0).floor
        lty = (wy / 32.0).floor
        vcache = {}
        locc = nil
        if @occ && !nosh && rad >= 80.0
          olh = rad > 160.0 ? 64.0 : 48.0          # light height above the floor
          locc = []
          @occ.each do |ox, oy, r, h, *_|
            dx0 = ox - wx
            dy0 = oy - wy
            d0 = Math.sqrt(dx0 * dx0 + dy0 * dy0)
            next if d0 < 40.0 || d0 > rad          # < 40px: the light's own holder
            maxd = h >= olh - 4.0 ? rad * 2.0 : d0 * olh / (olh - h)
            locc << [ox, oy, r, h, d0, maxd]
            break if locc.size >= 8
          end
          locc = nil if locc.empty?
        end
        j = j0
        while j <= j1
          cy = oy + j * cell + half
          ddy = cy - wy
          ety = (cy / 32.0).floor
          i = i0
          while i <= i1
            cx = ox + i * cell + half
            ddx = cx - wx
            d2 = ddx * ddx + ddy * ddy
            if d2 < r2
              t = 1.0 - d2 / r2
              lam = 0.55 + 0.45 * LIGHT_H / Math.sqrt(d2 + LIGHT_H2)
              # physical: inverse-square falloff (windowed so it ends at rad)
              att = phys ? inten * t * t * lam * 1.8 / (1.0 + d2 * inv_r0) : inten * t * t * lam
              if spot
                # window = directional beam falling into the room (south)
                cosv = ddy / Math.sqrt(d2 + 1.0)
                cf = (cosv - 0.20) / 0.80
                att = cf <= 0.0 ? 0.0 : att * (0.25 + 0.75 * cf)
              end
              if att > 0.01
                etx = (cx / 32.0).floor
                vis = if nosh
                        1.0
                      elsif hard
                        visibility(wx, wy, cx, cy, ltx, lty, etx, ety, smp, lsize)
                      else
                        tile_vis_interp(vcache, wx, wy, ltx, lty, cx, cy, etx, ety, smp, lsize)
                      end
                vis *= occ_factor(locc, wx, wy, cx, cy, olh, lsize) if locc && vis > 0.0
                if vis > 0.0
                  # wall faces (south-facing in top-down view) only catch light from the front
                  att *= 0.35 if wy < cy - 8 && solid?(etx, ety)
                  a = att * vis
                  k = i + j * gw
                  ar[k] += a * cr
                  ag[k] += a * cg
                  ab[k] += a * cb
                  # glossy surface: elongated highlight toward the viewer (south),
                  # like a lamp reflecting on a polished floor / wet street
                  if spec && etx >= 0 && ety >= 0 && etx < mw && ety < mh
                    ti = etx + ety * mw
                    gt = gls[ti]
                    if gt > 0.05 && ddy > -10.0
                      lx = ddx / (14.0 + 20.0 * (1.0 - gt))
                      ly = (ddy - 26.0) / (rad * (0.25 + 0.35 * gt))
                      lobe = 1.0 - lx * lx - ly * ly
                      if lobe > 0.0
                        sp = lobe * lobe * gt * spec * inten * vis
                        if mats[ti] == :metal && @br
                          # metals tint their reflection with their own color
                          mm = [@br[ti], @bg[ti], @bb[ti], 1.0].max
                          xr[k] += sp * cr * (0.4 + 0.6 * @br[ti] / mm)
                          xg[k] += sp * cg * (0.4 + 0.6 * @bg[ti] / mm)
                          xb[k] += sp * cb * (0.4 + 0.6 * @bb[ti] / mm)
                        else
                          xr[k] += sp * cr; xg[k] += sp * cg; xb[k] += sp * cb
                        end
                      end
                    end
                    # water caustics: light focused by moving waves into
                    # bright wandering lines on the lit water surface
                    if caus && mats[ti] == :water && a > 0.3
                      cz = Math.sin(cx * 0.19 + ct * 0.9) * Math.sin(cy * 0.23 - ct * 0.7) +
                           Math.sin((cx + cy) * 0.11 + ct * 1.3)
                      if cz > 0.6
                        cv = (cz - 0.6) * a * caus * 0.5
                        xr[k] += cv * cr; xg[k] += cv * cg; xb[k] += cv * cb
                      end
                    end
                  end
                end
              end
            end
            i += 1
          end
          j += 1
        end
      end
      if p[:bounce] > 0.0
        sr = sg = sb = 0.0
        k = 0
        while k < n
          sr += ar[k]; sg += ag[k]; sb += ab[k]
          k += 1
        end
        f = p[:bounce] * 3.0 / n
        br = [sr * f, 0.25].min
        bg = [sg * f, 0.25].min
        bb = [sb * f, 0.25].min
        k = 0
        while k < n
          ar[k] += br; ag[k] += bg; ab[k] += bb
          k += 1
        end
      end
      [ar, ag, ab, p[:ao] ? ambient_occlusion(p, ox, oy, gw, gh) : nil, spec ? [xr, xg, xb] : nil]
    end

    # Shadow rays are traced once per TILE (to its center) and cached per light,
    # then blended bilinearly across the tile -> ~10x fewer rays and naturally
    # soft penumbras. Walls never leak light into the floor behind them: for a
    # floor cell, solid neighbours borrow the cell's own tile visibility.
    def tvis(cache, wx, wy, ltx, lty, tx, ty, samples, size = 7.0)
      key = tx * 65536 + ty
      v = cache[key]
      return v if v
      cache[key] = visibility(wx, wy, tx * 32 + 16.0, ty * 32 + 16.0, ltx, lty, tx, ty, samples, size)
    end

    def tile_vis_interp(cache, wx, wy, ltx, lty, cx, cy, etx, ety, samples, size = 7.0)
      own = tvis(cache, wx, wy, ltx, lty, etx, ety, samples, size)
      return own if solid?(etx, ety)
      u = (cx - 16.0) / 32.0
      v = (cy - 16.0) / 32.0
      tx = u.floor
      ty = v.floor
      fx = u - tx
      fy = v - ty
      a = solid?(tx, ty)         ? own : tvis(cache, wx, wy, ltx, lty, tx, ty, samples, size)
      b = solid?(tx + 1, ty)     ? own : tvis(cache, wx, wy, ltx, lty, tx + 1, ty, samples, size)
      c = solid?(tx, ty + 1)     ? own : tvis(cache, wx, wy, ltx, lty, tx, ty + 1, samples, size)
      d = solid?(tx + 1, ty + 1) ? own : tvis(cache, wx, wy, ltx, lty, tx + 1, ty + 1, samples, size)
      (a * (1.0 - fx) + b * fx) * (1.0 - fy) + (c * (1.0 - fx) + d * fx) * fy
    end

    # Characters and standing objects as REAL occluders for the ray tracer:
    # a body of radius ~9px at the feet with a height from its sprite.
    def build_occluders(dxp, dyp)
      list = []
      chars = [$game_player]
      chars.concat($game_followers.to_a) if defined?($game_followers) && $game_followers
      $game_map.events.each_value do |ev|
        next if ev.real_x / 4 < dxp - 300 || ev.real_x / 4 > dxp + 940
        next if ev.real_y / 4 < dyp - 300 || ev.real_y / 4 > dyp + 780
        chars << ev
      end
      chars.each do |c|
        next if c.nil? || c.transparent || c.opacity < 20 || c.tile_id.to_i >= 384
        next if c.is_a?(Game_Event) && c.instance_variable_get(:@through)
        name = c.character_name.to_s
        next if name.empty? || name =~ /water_waves|sparkle|glitch|lightmap|portal_rays|tv_light|door|items|paper|book|rug|crater|arrows|marimo|clover/
        bmp = (RPG::Cache.character(name, c.character_hue) rescue nil)
        next unless bmp
        chh = bmp.height / 4
        next if chh < 36
        list << [c.real_x / 4.0 + 16, c.real_y / 4.0 + 26, 12.0, chh * 0.6]
        break if list.size >= 24
      end
      list
    end

    # Shadow of a body (radius r, height h, feet at ox,oy) from a light at
    # height LH: the ray light->cell is blocked if it passes within r of the
    # body AND the cell lies inside the shadow length d*LH/(LH-h). Returns the
    # light fraction left (soft penumbra at the edge and the shadow tip).
    def occ_factor(occs, wx, wy, cx, cy, lh, lsize = 8.0)
      ddx = cx - wx
      ddy = cy - wy
      dc = Math.sqrt(ddx * ddx + ddy * ddy)
      return 1.0 if dc < 1.0
      f = 1.0
      occs.each do |ox, oy, r, h, d0, maxd|
        next if dc <= d0 - r || dc > maxd
        dx0 = ox - wx
        dy0 = oy - wy
        t = (dx0 * ddx + dy0 * ddy) / dc
        next if t <= 0.0 || t >= dc
        perp = (dx0 * ddy - dy0 * ddx).abs / dc
        # penumbra width from light size and distances (similar triangles):
        # sharp right behind the body, softer farther away
        pw = lsize * (dc - d0) / (d0 > 1.0 ? d0 : 1.0)
        pw = 2.0 if pw < 2.0
        pw = r * 2.0 if pw > r * 2.0
        next if perp >= r + pw * 0.5
        core = (r + pw * 0.5 - perp) / pw
        core = 1.0 if core > 1.0
        tip = (maxd - dc) / (maxd - d0 + 1.0)
        tip = 1.0 if tip > 1.0
        f *= 1.0 - 0.9 * core * tip
      end
      f
    end

    # Contact shadows: floor cells next to walls get darker the closer they
    # are to the wall (like screen-space / ray traced AO).
    def ambient_occlusion(p, ox, oy, gw, gh)
      cell = p[:cell]
      half = cell / 2.0
      str = p[:ao]
      ao = Array.new(gw * gh, 1.0)
      j = 0
      while j < gh
        cy = oy + j * cell + half
        ty = (cy / 32.0).floor
        fy = (cy - ty * 32) / 32.0
        i = 0
        while i < gw
          cx = ox + i * cell + half
          tx = (cx / 32.0).floor
          unless solid?(tx, ty)
            fx = (cx - tx * 32) / 32.0
            o = 0.0
            o += (1.0 - fx) ** 2 if solid?(tx - 1, ty)
            o += fx ** 2 if solid?(tx + 1, ty)
            o += (1.0 - fy) ** 2 if solid?(tx, ty - 1)
            o += fy ** 2 if solid?(tx, ty + 1)
            o = 1.0 if o > 1.0
            ao[i + j * gw] = 1.0 - str * o
          end
          i += 1
        end
        j += 1
      end
      ao
    end

    # One-bounce global illumination ("instant radiosity"): rays from the
    # strongest lights hit walls; each hit becomes a small virtual light tinted
    # by the wall's own color -> color bleeding like a path tracer's indirect.
    def make_vpls(p, lights)
      out = []
      n = p[:gi_rays]
      gi = p[:gi]
      lights.each_with_index do |l, li|
        break if li >= 3
        wx, wy, rad, cr, cg, cb, inten = l
        ltx = (wx / 32.0).floor
        lty = (wy / 32.0).floor
        n.times do |q|
          ang = (q + 0.5) * 2.0 * Math::PI / n + li * 0.37
          dx = Math.cos(ang)
          dy = Math.sin(ang)
          s = 16.0
          while s < rad
            tx = ((wx + dx * s) / 32.0).floor
            ty = ((wy + dy * s) / 32.0).floor
            if (tx != ltx || ty != lty) && solid?(tx, ty)
              hx = wx + dx * (s - 14.0)
              hy = wy + dy * (s - 14.0)
              t = 1.0 - (s * s) / (rad * rad)
              e = inten * t * t * gi * 4.0 / n
              k = tx + ty * @mw
              r = @br ? @br[k] : 60.0
              g = @bg ? @bg[k] : 60.0
              b = @bb ? @bb[k] : 60.0
              m = [r, g, b, 1.0].max
              e *= Math.sqrt(m / 255.0)              # brighter walls bounce more
              out << [hx, hy, rad * 0.55, cr * r / m, cg * g / m, cb * b / m, e, 0.0, !p[:gi_shadow], false, nil, 16.0] if e > 0.02
              break
            end
            s += 12.0
          end
        end
      end
      out
    end

    #--------------------------------------------------------------------------
    # REAL Monte Carlo path tracing (indirect light).
    # On a half-res grid every cell shoots random rays (stratified + jittered
    # each pass). A ray marches through the map until it hits a wall; there we
    # do next-event estimation: pick one random light, trace a shadow ray to the
    # hit point, and reflect the light off the wall's albedo (its tile color).
    # With pt_bounces 2 the path continues from the hit in a new random
    # direction and gathers a second bounce. Samples are accumulated over
    # passes in a world-anchored buffer (progressive rendering) so the noise
    # converges to smooth GI, then GPU blur acts as the spatial denoiser.
    #--------------------------------------------------------------------------
    def light_att(l, x, y, phys)
      dx = x - l[0]
      dy = y - l[1]
      d2 = dx * dx + dy * dy
      r2 = l[2] * l[2]
      return 0.0 if d2 >= r2
      t = 1.0 - d2 / r2
      lam = 0.55 + 0.45 * LIGHT_H / Math.sqrt(d2 + LIGHT_H2)
      a = l[6] * t * t * lam
      phys ? a * 1.8 / (1.0 + d2 / ((l[2] * 0.3) ** 2)) : a
    end

    # direct light arriving at world point (x,y) from one randomly chosen light
    def nee(lights, x, y, phys)
      n = lights.size
      return [0.0, 0.0, 0.0] if n == 0
      l = lights[rand(n)]
      a = light_att(l, x, y, phys)
      return [0.0, 0.0, 0.0] if a <= 0.001
      ltx = (l[0] / 32.0).floor
      lty = (l[1] / 32.0).floor
      return [0.0, 0.0, 0.0] unless trace(l[0], l[1], x, y, ltx, lty, (x / 32.0).floor, (y / 32.0).floor)
      a *= n
      [l[3] * a, l[4] * a, l[5] * a]
    end

    # march a ray; returns [hit_x, hit_y, tile_x, tile_y] in front of the wall, or nil
    def march(x, y, dx, dy, maxd)
      stx = (x / 32.0).floor
      sty = (y / 32.0).floor
      s = 10.0
      while s < maxd
        tx = ((x + dx * s) / 32.0).floor
        ty = ((y + dy * s) / 32.0).floor
        if (tx != stx || ty != sty) && solid?(tx, ty)
          return [x + dx * (s - 12.0), y + dy * (s - 12.0), tx, ty]
        end
        s += 16.0
      end
      nil
    end

    def albedo(tx, ty)
      return [0.25, 0.25, 0.25] unless @br && tx >= 0 && ty >= 0 && tx < @mw && ty < @mh
      k = tx + ty * @mw
      [@br[k] / 255.0, @bg[k] / 255.0, @bb[k] / 255.0]
    end

    def path_trace(p, ox, oy, gw, gh, lights, acc)
      direct = lights.reject { |l| l[8] }
      phys = p[:phys]
      ps = p[:pt_scale] || 3
      cell2 = p[:cell] * ps
      cw = (gw + ps - 1) / ps
      ch = (gh + ps - 1) / ps
      spp = p[:pt_spp] || 1
      maxd = p[:pt_dist] || 200.0
      bounces = p[:pt_bounces] || 1
      gain = p[:pt_gain] || 1.5
      emis = {}
      (@emissive || []).each { |e| emis[((e[0] / 32).to_i) + ((e[1] / 32).to_i) * @mw] = e }
      # world-anchored accumulation buffer, reprojected when the camera moves
      prev = @pt_buf
      cr = Array.new(cw * ch, 0.0); cg = Array.new(cw * ch, 0.0); cb = Array.new(cw * ch, 0.0)
      cn = Array.new(cw * ch, 0)
      if prev && prev[4] == cell2
        pox, poy, pcw, pch, _c, pr, pg, pb, pn = prev
        di = (ox - pox) / cell2
        dj = (oy - poy) / cell2
        j = 0
        while j < ch
          pj = j + dj
          if pj >= 0 && pj < pch
            i = 0
            while i < cw
              pi = i + di
              if pi >= 0 && pi < pcw
                k = i + j * cw; q = pi + pj * pcw
                cr[k] = pr[q]; cg[k] = pg[q]; cb[k] = pb[q]; cn[k] = pn[q]
              end
              i += 1
            end
          end
          j += 1
        end
      end
      maxn = p[:pt_accum] || 24
      jit = rand * 2.0 * Math::PI
      j = 0
      while j < ch
        y = oy + j * cell2 + cell2 / 2.0
        i = 0
        while i < cw
          x = ox + i * cell2 + cell2 / 2.0
          k = i + j * cw
          unless solid?((x / 32.0).floor, (y / 32.0).floor)
            sr = sg = sb = 0.0
            s = 0
            while s < spp
              ang = jit + (s + rand) * 2.0 * Math::PI / spp
              thr_r = thr_g = thr_b = 1.0
              px = x; py = y
              dx = Math.cos(ang); dy = Math.sin(ang)
              b = 0
              while b < bounces
                hit = march(px, py, dx, dy, maxd)
                break unless hit
                hx, hy, tx, ty = hit
                al = albedo(tx, ty)
                thr_r *= al[0]; thr_g *= al[1]; thr_b *= al[2]
                e = emis[tx + ty * @mw]
                if e
                  sr += thr_r * e[2] * 0.6; sg += thr_g * e[3] * 0.6; sb += thr_b * e[4] * 0.6
                end
                l = nee(direct, hx, hy, phys)
                sr += thr_r * l[0]; sg += thr_g * l[1]; sb += thr_b * l[2]
                # continue the path: new random direction into the open hemisphere
                ang = rand * 2.0 * Math::PI
                dx = Math.cos(ang); dy = Math.sin(ang)
                px = hx; py = hy
                b += 1
              end
              s += 1
            end
            n = cn[k] + 1
            n = maxn if n > maxn
            w = 1.0 / n
            cr[k] += (sr / spp - cr[k]) * w
            cg[k] += (sg / spp - cg[k]) * w
            cb[k] += (sb / spp - cb[k]) * w
            cn[k] = n
          end
          i += 1
        end
        j += 1
      end
      @pt_buf = [ox, oy, cw, ch, cell2, cr, cg, cb, cn]
      # spatial denoiser (like NRD's role): 3x3 box over the accumulated GI
      fr = Array.new(cw * ch, 0.0); fg = Array.new(cw * ch, 0.0); fb = Array.new(cw * ch, 0.0)
      j = 0
      while j < ch
        i = 0
        while i < cw
          tr = tg = tb = 0.0
          nn = 0
          dj = -1
          while dj <= 1
            y2 = j + dj
            if y2 >= 0 && y2 < ch
              di = -1
              while di <= 1
                x2 = i + di
                if x2 >= 0 && x2 < cw
                  q = x2 + y2 * cw
                  tr += cr[q]; tg += cg[q]; tb += cb[q]
                  nn += 1
                end
                di += 1
              end
            end
            dj += 1
          end
          k = i + j * cw
          fr[k] = tr / nn; fg[k] = tg / nn; fb[k] = tb / nn
          i += 1
        end
        j += 1
      end
      cr = fr; cg = fg; cb = fb
      # add the converged indirect light into the fine grid
      ar, ag, ab = acc
      j = 0
      while j < gh
        i = 0
        while i < gw
          q = (i / ps) + (j / ps) * cw
          k = i + j * gw
          ar[k] += cr[q] * gain; ag[k] += cg[q] * gain; ab[k] += cb[q] * gain
          i += 1
        end
        j += 1
      end
      acc
    end

    # Temporal accumulation (denoiser / radiance cache): blend with last pass,
    # reprojected through the world-aligned grid, so light never flickers.
    def temporal(p, ox, oy, gw, gh, acc)
      a = p[:temporal]
      prev = @prev_acc
      @prev_acc = [ox, oy, gw, gh, p[:cell], acc]
      return acc unless prev && prev[4] == p[:cell]
      pox, poy, pgw, pgh, cell, pacc = prev
      di = (ox - pox) / cell
      dj = (oy - poy) / cell
      ar, ag, ab = acc
      par, pag, pab = pacc
      b = 1.0 - a
      j = 0
      while j < gh
        pj = j + dj
        if pj >= 0 && pj < pgh
          i = 0
          while i < gw
            pi = i + di
            if pi >= 0 && pi < pgw
              k = i + j * gw
              q = pi + pj * pgw
              ar[k] = ar[k] * b + par[q] * a
              ag[k] = ag[k] * b + pag[q] * a
              ab[k] = ab[k] * b + pab[q] * a
            end
            i += 1
          end
        end
        j += 1
      end
      acc
    end

    #--------------------------------------------------------------------------
    # Rendering
    #--------------------------------------------------------------------------
    def refresh(p)
      cell = p[:cell]
      dxp = $game_map.display_x / 4
      dyp = $game_map.display_y / 4
      ox = (dxp / cell) * cell - cell
      oy = (dyp / cell) * cell - cell
      gw = 640 / cell + 3
      gh = 480 / cell + 3
      lights = gather_lights(p, dxp, dyp)
      @nlights = lights.size
      @shadow_lights = lights
      @shvis = {}
      @occ = p[:obj_shadows] ? build_occluders(dxp, dyp) : nil
      if @tour_on && @tour_logged != $game_map.map_id && @frame > 30
        @tour_logged = $game_map.map_id
        log("TOUR lights: " + lights.map { |l| sprintf("(%d,%d r%d i%.2f c%.1f/%.1f/%.1f%s)", l[0], l[1], l[2], l[6], l[3], l[4], l[5], l[9] ? " spot" : "") }.join(" "))
        evs = $game_map.events.values.select { |e| (e.instance_variable_get(:@event).name rescue "").to_s =~ /window|light/i }
        log("TOUR light-ish events: " + evs.map { |e| "#{e.instance_variable_get(:@event).name}@#{e.x},#{e.y} page=#{!e.instance_variable_get(:@page).nil?} gfx=#{e.character_name}" }.join(", "))
      end
      @dark_scale = dark_scale
      lights += make_vpls(p, lights) if p[:gi]
      @nvpl = lights.size - @nlights
      acc = trace_grid(p, ox, oy, gw, gh, lights)
      acc = path_trace(p, ox, oy, gw, gh, lights, acc) if p[:pt]
      acc = temporal(p, ox, oy, gw, gh, acc) if p[:temporal]
      base = sample_base(ox, oy, dxp, dyp, gw, gh, cell)
      if @tour_on && base && @diag_map != [$game_map.map_id, $game_player.x, $game_player.y] && @frame > 20
        @diag_map = [$game_map.map_id, $game_player.x, $game_player.y]
        bsa = base[3]
        nz = bsa ? bsa.count { |v| v > 0.02 } : -1
        mx = bsa ? bsa.max : 0
        lit = 0
        if bsa
          bsa.each_with_index { |v, k| lit += 1 if v > 0.02 && acc[0][k] > 0.15 }
        end
        es = @eshadow || {}
        evs = $game_map.events.values.select { |e| e.character_name.to_s =~ /crater|pool/ }.map { |e| "#{e.character_name}@#{e.x},#{e.y} t=#{e.transparent} op=#{e.opacity} p=#{e.pattern} d=#{e.direction}" }
        log("DIAG map #{$game_map.map_id} niko #{$game_player.x},#{$game_player.y}: shadow cells in view=#{nz} max=#{mx.round(2)} lit_shadow_cells=#{lit} event_blocks=#{es.size} evs=#{evs.join('; ')}")
      end
      render(p, gw, gh, acc, base)
      @ox = ox
      @oy = oy
    end

    # How dark the game already made this room (screen tone + map ambient, the
    # same way Spriteset_Map combines them). Dark rooms get little extra
    # darkness so they don't turn pitch black; bright rooms get the full preset.
    def dark_scale
      t = $game_screen.tone
      a = $game_map.ambient
      k = bulb? ? 0.0 : 1.0
      r = t.red + a.red * k
      g = t.green + a.green * k
      b = t.blue + a.blue * k
      existing = -(r + g + b) / 765.0
      existing = 0.0 if existing < 0.0
      s = 1.0 - existing * 2.2
      s < 0.5 ? 0.5 : (s > 1.0 ? 1.0 : s)
    rescue StandardError
      1.0
    end

    # Per-tile base color read from the tileset/autotiles (what the floor and
    # walls really look like). With it the subtract layer removes base*(1-E)
    # (true multiply darkening) and the add layer adds base*(E-1) (brightening
    # that keeps the texture) -- no flat color wash.
    FALLBACK_BASE = 50.0

    # Reads a tile's actual pixels: average color, coverage, and the stats the
    # material classifier needs (saturation, hue, contrast, highlights).
    def avg_rect(bmp, x0, y0, w, h)
      r = g = b = a = 0.0
      n = 0
      m = 0
      l1 = l2 = hi = 0.0
      gr = gg = gb = 0.0
      ng = 0
      tile = (w == 32 && h == 32)
      shp = tile ? Array.new(16, 0.0) : nil    # painted shadow, 4x4 pieces of 8px
      y = y0 + 2
      while y < y0 + h
        x = x0 + 2
        while x < x0 + w
          c = bmp.get_pixel(x, y)
          al = c.alpha / 255.0
          r += c.red * al; g += c.green * al; b += c.blue * al; a += al
          if al > 0.1
            lum = c.red * 0.3 + c.green * 0.59 + c.blue * 0.11
            l1 += lum; l2 += lum * lum; m += 1
            hi = lum if lum > hi
            cmx = c.red > c.green ? c.red : c.green
            cmx = c.blue if c.blue > cmx
            cmn = c.red < c.green ? c.red : c.green
            cmn = c.blue if c.blue < cmn
            # glowing pixel: very bright, or bright AND strongly colored (neon)
            if cmx > 200 && (lum > 165 || cmx - cmn > 120)
              gr += c.red; gg += c.green; gb += c.blue; ng += 1
            end
            # painted shadow pixel: dark AND see-through (an artist's shadow
            # overlay), not an opaque dark outline
            if shp && al < 0.92 && lum < 60 && cmx - cmn < 70
              shp[((x - x0) / 8) + ((y - y0) / 8) * 4] += al * 0.25
            end
          end
          n += 1
          x += 4
        end
        y += 4
      end
      return nil if n == 0 || a < 0.001 || m == 0
      r /= a; g /= a; b /= a
      mean = l1 / m
      var = l2 / m - mean * mean
      con = var > 0 ? Math.sqrt(var) : 0.0
      mx = [r, g, b].max
      mn = [r, g, b].min
      sat = mx > 0 ? (mx - mn) / mx : 0.0
      glow = nil
      if ng > 0
        gm = [gr, gg, gb].max
        glow = [gr / gm, gg / gm, gb / gm, ng.to_f / m, sat]
      end
      shp = nil if shp && shp.max < 0.08
      [r, g, b, a / n, classify(r, g, b, mx, mn, sat, con, hi, mean), glow, shp]
    end

    def hue_of(r, g, b, mx, mn)
      d = mx - mn
      return 0.0 if d < 1e-6
      h = if mx == r then ((g - b) / d) % 6
          elsif mx == g then (b - r) / d + 2
          else (r - g) / d + 4
          end
      h * 60.0
    end

    # Material from the tile's look -> [kind, gloss]. Floors are later
    # overridden by the game's own footstep terrain tags (most reliable).
    def classify(r, g, b, mx, mn, sat, con, hi, mean)
      hue = hue_of(r, g, b, mx, mn)
      return [:water, 0.85] if sat > 0.35 && hue >= 180 && hue <= 235 && mean > 50 && con < 40
      return [:glass, 0.70] if mean > 140 && sat > 0.15 && hue >= 170 && hue <= 290
      return [:metal, 0.55] if sat < 0.22 && mean > 45 && (con > 22 || hi > mean * 1.7)
      return [:plant, 0.00] if hue >= 70 && hue <= 165 && sat > 0.25
      return [:wood, 0.15]  if hue >= 10 && hue <= 50 && sat > 0.25
      return [:tile, 0.30]  if sat < 0.25 && con < 22
      [:matte, 0.08]
    end

    # what each footstep sound means as a surface (gloss = reflectivity)
    STEP_MAT = {
      "step_wood" => [:wood, 0.18], "step_boat" => [:wood, 0.15],
      "step_tile" => [:tile, 0.45], "step_tile_soft" => [:tile, 0.28],
      "step_metal" => [:metal, 0.60], "step_grate" => [:metal, 0.30],
      "step_splash" => [:water, 0.85], "step_grass" => [:plant, 0.0],
      "step_gravel" => [:stone, 0.05]
    }
    # region hints from the tileset name (applied to otherwise-unknown walls)
    TILESET_HINT = [
      [/factory|obsdeck|elevator/, [:metal, 0.45]],
      [/tower|unreality|finale/,   [:tile, 0.40]],
      [/mineshaft|red_ground/,     [:stone, 0.06]],
    ]

    def build_materials(w, h, top)
      @gloss = Array.new(w * h, 0.0)
      @mat = Array.new(w * h, :matte)
      hint = nil
      TILESET_HINT.each { |rx, v| hint = v if @tileset_key =~ rx }
      sfx = nil
      begin
        tid = $game_map.instance_variable_get(:@map).tileset_id
        sfx = ::FOOTSTEP_SFX[tid - 1] if defined?(::FOOTSTEP_SFX)
      rescue StandardError
        sfx = nil
      end
      k = 0
      while k < w * h
        mt = top[k]
        if mt
          mt = hint if hint && (mt[0] == :matte || mt[0] == :tile) && @solid.getbyte(k) == 1
          @mat[k] = mt[0]
          @gloss[k] = mt[1]
        end
        k += 1
      end
      if sfx
        y = 0
        while y < h
          x = 0
          while x < w
            tag = ($game_map.terrain_tag(x, y) rescue 0).to_i
            if tag > 0 && (snd = sfx[tag - 1])
              snd = snd[0] if snd.is_a?(Array)
              if (mt = STEP_MAT[snd])
                @mat[x + y * w] = mt[0]
                @gloss[x + y * w] = mt[1]
              end
            end
            x += 1
          end
          y += 1
        end
      end
      # animated water surfaces are events in OneShot
      $game_map.events.each_value do |ev|
        next unless ev.character_name.to_s =~ /water_waves/
        k = ev.x + ev.y * w
        next if k < 0 || k >= w * h
        @mat[k] = :water
        @gloss[k] = 0.85
      end
      counts = Hash.new(0)
      @mat.each { |m| counts[m] += 1 }
      log("materials map #{$game_map.map_id} (#{@tileset_key}): " + counts.map { |m, c| "#{m}=#{c}" }.join(" ") +
          " painted_shadow_tiles=#{(@bshadow || {}).size}" +
          " sprite_shadow_blocks=#{(event_shadows || {}).size}") if @stats
    rescue StandardError => e
      log("materials failed: #{e.class}: #{e.message}")
      @gloss = nil
    end

    def tile_avg(id)
      return nil if id.nil? || id < 48
      key = [@tileset_key, id]
      return @tavg[key] if @tavg.key?(key)
      res = nil
      begin
        if id >= 384
          bmp = @tileset_bmp
          if bmp
            x0 = (id - 384) % 8 * 32
            y0 = (id - 384) / 8 * 32
            res = avg_rect(bmp, x0, y0, 32, 32) if y0 + 32 <= bmp.height
          end
        else
          name = $game_map.autotile_names[id / 48 - 1]
          if name && !name.empty?
            bmp = RPG::Cache.autotile(name)
            res = avg_rect(bmp, 0, 0, [bmp.width, 96].min, [bmp.height, 128].min)
          end
        end
      rescue StandardError
        res = nil
      end
      @tavg[key] = res
    end

    def build_base
      m = $game_map
      @tavg ||= {}
      @tileset_key = m.tileset_name.to_s
      @tileset_bmp = nil
      if @tileset_key != "" && @tileset_key != "blank"
        @tileset_bmp = (RPG::Cache.tileset(@tileset_key) rescue nil)
      end
      w = @mw
      h = @mh
      data = m.data
      br = Array.new(w * h, FALLBACK_BASE)
      bg = Array.new(w * h, FALLBACK_BASE)
      bb = Array.new(w * h, FALLBACK_BASE)
      top = Array.new(w * h)
      @glow_tiles = []
      @bshadow = {}
      y = 0
      while y < h
        x = 0
        while x < w
          r = g = b = 0.0
          cov = 0.0
          layer = 0
          while layer < 3
            t = tile_avg(data[x, y, layer])
            if t
              a = t[3]
              # a pure shadow-overlay tile (dark + see-through) is not part of
              # the ground's color: it is applied as a painted shadow instead
              a = 0.0 if t[6] && a < 0.75 && (t[0] * 0.3 + t[1] * 0.59 + t[2] * 0.11) < 60
              r = r * (1 - a) + t[0] * a
              g = g * (1 - a) + t[1] * a
              b = b * (1 - a) + t[2] * a
              cov = cov + a * (1 - cov)
              top[x + y * w] = t[4] if a > 0.5 && t[4]
              if t[6]
                cur = (@bshadow[x + y * w] ||= Array.new(16, 0.0))
                16.times { |q| cur[q] = 1.0 - (1.0 - cur[q]) * (1.0 - t[6][q]) }
              end
              gl = t[5]
              if gl && gl[3] >= 0.03
                last = @glow_tiles[-1]
                if last && last[0] == x && last[1] == y
                  @glow_tiles[-1] = [x, y] + gl if gl[3] > last[5]
                else
                  @glow_tiles << ([x, y] + gl)
                end
              end
            end
            layer += 1
          end
          if cov > 0.05
            k = x + y * w
            br[k] = r; bg[k] = g; bb[k] = b
          end
          x += 1
        end
        y += 1
      end
      @br = br; @bg = bg; @bb = bb
      find_emissive(w, h)
      build_materials(w, h, top)
    end

    # Emissive surfaces: every tile whose pixels contain glowing colors
    # (lamps, neon tubes, screens, lit windows, crystals...) becomes a light in
    # its own color; strength and size follow how much of the tile glows.
    def find_emissive(w, h)
      @emissive = []
      cand = @glow_tiles || []
      if cand.size > (w * h) / 12
        # bright map (snow, white rooms): keep only the most lamp-like tiles
        cand = cand.sort_by { |t| -(t[5] * (0.3 + t[6])) }[0, 300]
      end
      # neighbouring glowing tiles are ONE light (a window, a neon tube, a
      # monitor wall): group them into 3x3-tile area lights instead of many
      # stacked point lights (which oversaturated into flat colored blocks)
      buckets = {}
      cand.each do |x, y, r, g, b, frac, _sat|
        (buckets[(x / 3) * 100003 + (y / 3)] ||= []) << [x, y, r, g, b, frac]
      end
      buckets.each_value do |ts|
        wsum = 0.0
        sx = sy = sr = sg = sb = 0.0
        ts.each do |x, y, r, g, b, frac|
          wsum += frac
          sx += (x * 32 + 16.0) * frac; sy += (y * 32 + 16.0) * frac
          sr += r * frac; sg += g * frac; sb += b * frac
        end
        next if wsum <= 0.0
        m = [sr, sg, sb].max
        k = wsum > 1.0 ? 1.0 : wsum
        rad = 70.0 + 38.0 * Math.sqrt(ts.size)
        rad = 190.0 if rad > 190.0
        cr = sr / m; cg = sg / m; cb = sb / m
        cr = cr * 0.75 + 0.25; cg = cg * 0.75 + 0.25; cb = cb * 0.75 + 0.25
        @emissive << [sx / wsum, sy / wsum, cr, cg, cb, rad, 0.22 + 0.38 * k]
      end
    end

    # Painted shadows that are part of EVENT sprites (craters, pools, the
    # elevator...): their see-through dark pixels are stamped into a world
    # grid of 8px blocks, so light can lift them piece by piece too.
    SHADOW_SKIP = /countdown|marimo|fishtank|light|portal|screen|tv_|sparkle|glitch|water_waves/

    def sprite_shadow_mask(name, hue, sx, sy, cw, chh)
      key = [name, hue, sx, sy]
      @smask ||= {}
      return @smask[key] if @smask.key?(key)
      mask = nil
      bmp = (RPG::Cache.character(name, hue) rescue nil)
      if bmp
        bw = (cw + 7) / 8
        bh = (chh + 7) / 8
        acc = Array.new(bw * bh, 0.0)
        cnt = Array.new(bw * bh, 0)
        any = false
        y = 1
        while y < chh
          x = 1
          while x < cw
            c = bmp.get_pixel(sx + x, sy + y)
            k = (x / 8) + (y / 8) * bw
            cnt[k] += 1
            al = c.alpha / 255.0
            if al > 0.02 && al < 0.92
              lum = c.red * 0.3 + c.green * 0.59 + c.blue * 0.11
              cmx = [c.red, c.green, c.blue].max
              cmn = [c.red, c.green, c.blue].min
              if lum < 60 && cmx - cmn < 70
                acc[k] += al
                any = true
              end
            end
            x += 3
          end
          y += 3
        end
        if any
          mask = [bw, bh, acc.each_with_index.map { |v, k2| cnt[k2] > 0 ? v / cnt[k2] : 0.0 }]
        end
      end
      @smask[key] = mask
    end

    def event_shadows
      return nil unless $game_map
      sig = []
      evs = []
      $game_map.events.each_value do |ev|
        name = ev.character_name.to_s
        next if name.empty? || ev.transparent || ev.tile_id.to_i >= 384 || name =~ SHADOW_SKIP
        evs << ev
        sig << ev.id << ev.real_x << ev.real_y << ev.pattern << ev.direction << name.hash << ev.opacity
      end
      return @eshadow if @eshadow && sig == @eshadow_sig
      @eshadow_sig = sig
      grid = {}
      evs.each do |ev|
        name = ev.character_name.to_s
        bmp = (RPG::Cache.character(name, ev.character_hue) rescue nil)
        next unless bmp
        cw = bmp.width / 4
        chh = bmp.height / 4
        sx = ev.pattern * cw
        sy = (ev.direction - 2) / 2 * chh
        m = sprite_shadow_mask(name, ev.character_hue, sx, sy, cw, chh)
        next unless m
        bw, bh, vals = m
        wx0 = (ev.real_x / 4 + 16 - cw / 2).to_i
        wy0 = (ev.real_y / 4 + 32 - chh).to_i
        op = ev.opacity / 255.0
        bh.times do |by|
          bw.times do |bx|
            v = vals[bx + by * bw] * op
            next if v < 0.04
            key = ((wx0 + bx * 8 + 4) >> 3) * 100003 + ((wy0 + by * 8 + 4) >> 3)
            old = grid[key] || 0.0
            grid[key] = 1.0 - (1.0 - old) * (1.0 - v)
          end
        end
      end
      @eshadow = grid
    rescue StandardError => e
      log("event shadow error: #{e.class}: #{e.message}") unless @esh_warned
      @esh_warned = true
      nil
    end

    def sample_base(ox, oy, dxp, dyp, gw, gh, cell)
      return nil unless @br
      n = gw * gh
      br = Array.new(n, 0.0); bg = Array.new(n, 0.0); bb = Array.new(n, 0.0)
      es = event_shadows
      es = nil if es && es.empty?
      bs = ((@bshadow && !@bshadow.empty?) || es) ? Array.new(n, 0.0) : nil
      w = @mw
      h = @mh
      half = cell / 2
      j = 0
      while j < gh
        ty = (oy + j * cell + half) / 32
        i = 0
        while i < gw
          tx = (ox + i * cell + half) / 32
          if tx >= 0 && ty >= 0 && tx < w && ty < h
            t = tx + ty * w
            k = i + j * gw
            br[k] = @br[t]; bg[k] = @bg[t]; bb[k] = @bb[t]
            if bs && (sp = @bshadow[t])
              px = (ox + i * cell + half) % 32
              py = (oy + j * cell + half) % 32
              bs[k] = sp[(px / 8) + (py / 8) * 4]
            end
            if es && (ev = es[((ox + i * cell + half) >> 3) * 100003 + ((oy + j * cell + half) >> 3)])
              bs[k] = 1.0 - (1.0 - bs[k]) * (1.0 - ev)
            end
          end
          i += 1
        end
        j += 1
      end
      [br, bg, bb, bs]
    end

    def render(p, gw, gh, acc, base = nil)
      ensure_bitmaps(p, gw, gh)
      ar, ag, ab = acc
      dk = p[:dark] * (@dark_scale || 1.0)        # how much unlit areas dim (multiply)
      amb = 1.0 - dk
      gain = dk + (p[:boost] || 0.6)              # lit areas go above vanilla brightness
      tr, tg, tb = p[:tint]
      atr, atg, atb = p[:amb_tint] || [1.0, 1.0, 1.0]   # cool sky-fill in shadows
      ao = acc[3]
      xs = acc[4]                                        # specular reflections
      xsr, xsg, xsb = xs if xs
      haze = p[:volume] ? p[:volume] * 255.0 : nil
      unsh = base && p[:unshadow] != false && !@nounshadow ? (p[:unshadow] || 1.0) : nil
      lvl = Array.new(gw * gh, 1.0)                      # light level per cell (for objects)
      filmic = p[:filmic]
      cap = filmic ? 3.0 : 1.6                            # HDR range before tone mapping
      expo = p[:exposure] ? (@expo ||= 1.0) : 1.0
      esum = 0.0
      gl = p[:glow] * 255.0
      sh = @shade_s
      gb = @glow_s
      sh.fill_rect(sh.rect, Color.new(0, 0, 0))
      gb.fill_rect(gb.rect, Color.new(0, 0, 0))
      col = Color.new(0, 0, 0)
      j = 0
      while j < gh
        i = 0
        while i < gw
          k = i + j * gw
          r = ar[k]; g = ag[k]; b = ab[k]
          # smooth HDR compression (a hard clamp made a flat disk with a
          # visible ring around strong lights)
          r = r / (1.0 + r / cap)
          g = g / (1.0 + g / cap)
          b = b / (1.0 + b / cap)
          o = ao ? ao[k] : 1.0
          er = (amb * atr + gain * r * tr) * o
          eg = (amb * atg + gain * g * tg) * o
          eb = (amb * atb + gain * b * tb) * o
          esum += er + eg + eb
          if filmic
            # eye adaptation + soft highlight shoulder: bright stays comfy
            er *= expo; eg *= expo; eb *= expo
            er = 0.9 + (er - 0.9) / (1.0 + (er - 0.9) * 1.8) if er > 0.9
            eg = 0.9 + (eg - 0.9) / (1.0 + (eg - 0.9) * 1.8) if eg > 0.9
            eb = 0.9 + (eb - 0.9) / (1.0 + (eb - 0.9) * 1.8) if eb > 0.9
          end
          r = 1.0 if r > 1.0
          g = 1.0 if g > 1.0
          b = 1.0 if b > 1.0
          if base
            cr = base[0][k]; cg = base[1][k]; cb = base[2][k]
          else
            cr = cg = cb = 80.0
          end
          ss = (base && base[3]) ? base[3][k] : 0.0
          ss = 0.85 if ss > 0.85
          ps = 1.0 - ss                       # what the painted shadow leaves
          sr = er < 1.0 ? cr * ps * (1.0 - er) : 0.0
          sg = eg < 1.0 ? cg * ps * (1.0 - eg) : 0.0
          sb = eb < 1.0 ? cb * ps * (1.0 - eb) : 0.0
          if sr > 0.5 || sg > 0.5 || sb > 0.5
            col.set(sr, sg, sb, 255)
            sh.set_pixel(i, j, col)
          end
          # brightening above vanilla is capped (+35%) so bright lamp areas
          # stay detailed instead of washing out into flat color
          gr = er > 1.0 ? cr * ((er > 1.35 ? 1.35 : er) - 1.0) : 0.0
          gg = eg > 1.0 ? cg * ((eg > 1.35 ? 1.35 : eg) - 1.0) : 0.0
          gbb = eb > 1.0 ? cb * ((eb > 1.35 ? 1.35 : eb) - 1.0) : 0.0
          lvl[k] = (er + eg + eb) / 3.0
          if unsh && ss > 0.02
            # the artist's shadow is removed exactly as much as DIRECT light
            # reaches this 8px piece: full light -> gone, half -> half, none
            # -> untouched. So light at a pool's edge only lifts that edge.
            # direct light share of the total (never more than the total), so a
            # fully lit piece ends up exactly as bright as the lit ground beside it
            dr = gain * r * tr; dg = gain * g * tg; db = gain * b * tb
            dr = er if dr > er
            dg = eg if dg > eg
            db = eb if db > eb
            gr += cr * ss * dr * unsh; gg += cg * ss * dg * unsh; gbb += cb * ss * db * unsh
          end
          if haze
            # light scattering in the air: follows the traced visibility, so
            # openings and windows throw visible shafts, walls cut them off
            # squared: only real shafts near strong lights, no foggy wash
            gr += r * r * haze; gg += g * g * haze; gbb += b * b * haze
          end
          if xs
            # soft-clipped so reflections shine but never blind you
            v = xsr[k]; gr += 170.0 * v / (1.0 + v) if v > 0.002
            v = xsg[k]; gg += 170.0 * v / (1.0 + v) if v > 0.002
            v = xsb[k]; gbb += 170.0 * v / (1.0 + v) if v > 0.002
          end
          # small colored bloom right at the light cores
          m = r > g ? r : g
          m = b if b > m
          if m > 0.5
            f = (m - 0.5) * 2.0
            f = f * f * gl
            gr += r * f; gg += g * f; gbb += b * f
          end
          if gr > 0.5 || gg > 0.5 || gbb > 0.5
            col.set(gr, gg, gbb, 255)
            gb.set_pixel(i, j, col)
          end
          i += 1
        end
        j += 1
      end
      @lvl = lvl
      @lvl_gw = gw
      @lvl_gh = gh
      @lvl_cell = p[:cell]
      if p[:exposure]
        # slow auto-exposure (like HL2's HDR eye adaptation)
        avg = esum / (3.0 * gw * gh)
        want = avg > 0.01 ? 0.95 / avg : 1.15
        @expo += (want - @expo) * 0.06
        @expo = 0.85 if @expo < 0.85
        @expo = 1.0 if @expo > 1.0         # never brighten darkness
      end
      if p[:blur] > 0
        [[@shade_m, sh], [@glow_m, gb]].each do |mid, small|
          soft_upscale(mid, small, p[:cell] / 2, p[:blur])
        end
        @shade.bitmap = @shade_m
        @glow.bitmap = @glow_m
        z = 2.0
      else
        @shade.bitmap = sh
        @glow.bitmap = gb
        z = p[:cell].to_f
      end
      [@shade, @glow].each { |s| s.zoom_x = z; s.zoom_y = z }
    end

    # Upscale the light grid and soften it on the GPU: the grid is stretched
    # several times with sub-cell offsets and averaged by alpha (layer i drawn at
    # opacity 255/i gives an equal-weight average) -> a box blur made of blits.
    def soft_upscale(mid, small, s, passes)
      mid.clear
      dst = mid.rect
      src = small.rect
      if mid.respond_to?(:blur)
        mid.stretch_blt(dst, small, src)
        passes.times { mid.blur }
        return
      end
      mid.stretch_blt(dst, small, src)
      tmp = @tmp_m
      # separable box blur, one light-cell wide per tap, ping-ponging between
      # two bitmaps. Center is drawn first at full opacity so edges never go
      # transparent; tap n is drawn at 255/n -> equal-weight average.
      # Offsets must NOT all equal the cell size: shifting by whole cells keeps
      # every cell a flat block (that was the blocky look). Mix wide, half and
      # quarter-cell taps so cell edges really melt into smooth gradients.
      q = s / 4; q = 1 if q < 1
      h = s / 2; h = 1 if h < 1
      seq = [s, h, q, h, q, s]
      passes.times do |i|
        d = seq[i % seq.size]
        blur_pass(tmp, mid, d, 0)
        blur_pass(mid, tmp, 0, d)
      end
      blur_pass(tmp, mid, q, 0)
      blur_pass(mid, tmp, 0, q)
    end

    def blur_pass(dst, src, dx, dy)
      dst.clear
      r = src.rect
      dst.blt(0, 0, src, r)
      dst.blt(-dx, -dy, src, r, 128)
      dst.blt(dx, dy, src, r, 85)
    end

    def ensure_bitmaps(p, gw, gh)
      sig = [gw, gh, p[:cell]]
      return if @bmp_sig == sig
      [@shade_s, @glow_s, @shade_m, @glow_m, @tmp_m].each { |b| b.dispose if b && !b.disposed? }
      @shade_s = Bitmap.new(gw, gh)
      @glow_s = Bitmap.new(gw, gh)
      s = p[:cell] / 2
      @shade_m = Bitmap.new(gw * s, gh * s)
      @glow_m = Bitmap.new(gw * s, gh * s)
      @tmp_m = Bitmap.new(gw * s, gh * s)
      @bmp_sig = sig
    end

    def ensure_layers
      if @vp.nil? || @vp.disposed?
        @vp = Viewport.new(0, 0, 640, 480)
        # z=1: right above the map viewport (z 0) and BELOW every UI element:
        # windows (100+), lightmaps (200), pictures/computer screens (500),
        # menus/inventory/messages/documents (9998-9999). Never touches UI.
        @vp.z = 1
        @shade = Sprite.new(@vp)
        @shade.blend_type = 2
        @shade.z = 0
        @glow = Sprite.new(@vp)
        @glow.blend_type = 1
        @glow.z = 1
      end
      @vp.visible = true
    end

    def place_layers
      return unless @ox
      dxp = $game_map.display_x / 4
      dyp = $game_map.display_y / 4
      @shade.x = @glow.x = @ox - dxp
      @shade.y = @glow.y = @oy - dyp
      @vp.ox = $game_screen.shake rescue 0
      # fade the glow with screen fades so it never shows on a black screen
      tone = $game_screen.tone
      f = 1.0 + (tone.red + tone.green + tone.blue) / 765.0
      f = 0.0 if f < 0.0
      f = 1.0 if f > 1.0
      @glow.opacity = 255 * f
      @shade.opacity = 255
    end

    #--------------------------------------------------------------------------
    # Objects: per-sprite lighting + reflections
    #--------------------------------------------------------------------------
    def level_at(x, y)
      return 1.0 unless @lvl && @ox
      c = @lvl_cell
      i = ((x - @ox) / c).floor
      j = ((y - @oy) / c).floor
      return 1.0 if i < 0 || j < 0 || i >= @lvl_gw || j >= @lvl_gh
      @lvl[i + j * @lvl_gw]
    end

    def gloss_at(tx, ty)
      return 0.0 unless @gloss && tx >= 0 && ty >= 0 && tx < @mw && ty < @mh
      @gloss[tx + ty * @mw]
    end

    def update_objects(p)
      ss = $scene.instance_variable_get(:@spriteset)
      return unless ss
      vp = ss.instance_variable_get(:@viewport)
      sprites = ss.instance_variable_get(:@character_sprites) || []
      if @obj_ss != ss
        @refl = {}          # old spriteset (and its viewport) is gone
        @lit = {}
        @obj_ss = ss
      end
      # 1) glow sprites (OneShot lightmaps: bed, jars, niko...) draw ABOVE the
      #    lighting layer, so light them individually from the traced grid
      sprites.each do |cs|
        ls = cs.instance_variable_get(:@light_sprite)
        ch = cs.character
        next unless ls && ch && !ls.disposed?
        lv = level_at(ch.real_x / 4.0 + 16, ch.real_y / 4.0 + 16)
        # these sprites are ADDITIVE: a positive tint would light up their
        # transparent pixels (gray box), so only ever dim them, via opacity
        f = lv < 0.3 ? 0.3 : (lv > 1.0 ? 1.0 : lv)
        ls.opacity = ch.opacity * f
        @lit_sprites ||= {}
        @lit_sprites[ls.object_id] = ls
      end
      # 2) reflections: characters standing on glossy floors / water get a
      #    mirrored copy below their feet, faded by the material's gloss
      return hide_reflections unless p[:refl] && vp && !vp.disposed?
      seen = {}
      count = 0
      chars = [$game_player]
      chars.concat($game_followers.to_a) if defined?($game_followers) && $game_followers
      dxp = $game_map.display_x / 4
      dyp = $game_map.display_y / 4
      $game_map.events.each_value do |ev|
        next if ev.real_x / 4 < dxp - 64 || ev.real_x / 4 > dxp + 704
        next if ev.real_y / 4 < dyp - 64 || ev.real_y / 4 > dyp + 544
        chars << ev
      end
      t = @frame
      chars.each do |c|
        break if count >= 40
        next if c.nil? || c.transparent || c.opacity < 20 || c.tile_id.to_i >= 384
        name = c.character_name.to_s
        next if name.empty? || name =~ /water_waves|sparkle|glitch|lightmap/
        g = gloss_at(c.x, c.y)
        mt = @mat ? @mat[c.x + c.y * @mw] : nil
        # seen from above, only water and metal reflect visibly (Fresnel:
        # dielectrics reflect a few % at steep angles) -> no mirror floors
        next unless mt == :water || mt == :metal
        bmp = (RPG::Cache.character(name, c.character_hue) rescue nil)
        next unless bmp
        spr = @refl[c.object_id]
        if spr.nil? || spr.disposed?
          spr = Sprite.new(vp)
          spr.angle = 180          # rotate 180 + mirror = vertical flip
          spr.mirror = true
          spr.z = 1                # on the floor, under every character
          @refl[c.object_id] = spr
        end
        cw = bmp.width / 4
        chh = bmp.height / 4
        spr.bitmap = bmp unless spr.bitmap.equal?(bmp)
        spr.src_rect.set(c.pattern * cw, (c.direction - 2) / 2 * chh, cw, chh)
        spr.ox = cw / 2
        spr.oy = chh
        water = (@mat && @mat[c.x + c.y * @mw] == :water)
        spr.x = c.screen_x
        spr.y = c.screen_y - 2
        if water
          # gentle, slow ripple only on water
          spr.zoom_x = 1.0 + 0.015 * Math.sin(t * 0.05 + c.x)
          spr.zoom_y = 0.9
          spr.tone = WATER_TONE
        else
          spr.zoom_x = 1.0
          spr.zoom_y = 0.75 + 0.2 * g
          spr.tone = FLOOR_TONE
        end
        lv = level_at(c.real_x / 4.0 + 16, c.real_y / 4.0 + 16)
        lv = 1.0 if lv > 1.0
        target = 255.0 * (mt == :water ? 0.30 : 0.14) * (p[:refl] / 0.6) * (c.opacity / 255.0) * (0.35 + 0.65 * lv)
        # smooth toward the target so path-traced noise can't make it breathe
        @refl_op ||= {}
        cur = @refl_op[c.object_id] || target
        cur += (target - cur) * 0.08
        cur = target if (target - cur).abs < 1.0
        @refl_op[c.object_id] = cur
        spr.opacity = cur.round
        spr.visible = true
        seen[c.object_id] = true
        count += 1
      end
      @refl.each { |id, s| s.visible = false if !seen[id] && !s.disposed? }
      update_shadows(p, vp, chars)
      update_contact(p, vp, chars)
    rescue StandardError => e
      log("objects error: #{e.class}: #{e.message}") unless @obj_warned
      @obj_warned = true
    end

    WATER_TONE = Tone.new(-40, -15, 25, 60)
    FLOOR_TONE = Tone.new(-30, -30, -25, 40)

    SHADOW_TONE = Tone.new(-255, -255, -255, 0)

    # 3) Ray traced object shadows: every character / object (Niko, NPCs,
    #    robots, boxes...) casts a silhouette shadow on the floor, pointing
    #    away from the strongest light that can actually SEE it (shadow ray),
    #    longer the farther it stands from that light.
    # Physically based: a standing object of height h lit by a light at
    # height H casts a shadow of length ~ h * d / (H - h) away from it (clamped).
    # Flat things (papers, rugs) and walk-through events cast nothing. Each
    # object can cast up to 2 shadows (2 strongest lights that SEE it, checked
    # with a shadow ray), each weighted by that light's strength.
    def update_shadows(p, vp, chars)
      @shadows ||= {}
      unless p[:obj_shadows] && p[:sil_shadows] && @shadow_lights
        @shadows.each_value { |s| s.visible = false unless s.disposed? }
        return
      end
      seen = {}
      n = 0
      chars.each do |c|
        break if n >= 40
        next if c.nil? || c.transparent || c.opacity < 20 || c.tile_id.to_i >= 384
        next if c.is_a?(Game_Event) && c.instance_variable_get(:@through)
        name = c.character_name.to_s
        next if name.empty? || name =~ /water_waves|sparkle|glitch|lightmap|portal_rays|tv_light|door|items|paper|book|rug|crater|arrows|marimo/
        bmp = (RPG::Cache.character(name, c.character_hue) rescue nil)
        next unless bmp
        cw = bmp.width / 4
        chh = bmp.height / 4
        next if chh < 36                       # flat / tiny graphics: no shadow
        fx = c.real_x / 4.0 + 16
        fy = c.real_y / 4.0 + 28
        cands = []
        @shadow_lights.each do |l|
          next if l[8]
          dx = fx - l[0]
          dy = fy - l[1]
          next if dx * dx + dy * dy < 1600.0     # its own light (< 40px): no self-shadow
          a = light_att(l, fx, fy, true)
          next if a < 0.06
          key = c.object_id * 7919 + l[0].to_i * 131 + l[1].to_i
          v = @shvis[key]
          if v.nil?
            ok = trace(l[0], l[1], fx, fy - 10, (l[0] / 32.0).floor, (l[1] / 32.0).floor,
                       (fx / 32.0).floor, ((fy - 10) / 32.0).floor)
            v = @shvis[key] = ok ? 1.0 : 0.0
          end
          cands << [a * v, l] if v > 0.0
        end
        cands.sort_by! { |e| -e[0] }
        cands[0, 2].each_with_index do |(str, l), si|
          id = c.object_id * 2 + si
          spr = @shadows[id]
          if spr.nil? || spr.disposed?
            spr = Sprite.new(vp)
            spr.tone = SHADOW_TONE
            spr.z = 1
            @shadows[id] = spr
          end
          spr.bitmap = bmp unless spr.bitmap.equal?(bmp)
          spr.src_rect.set(c.pattern * cw, (c.direction - 2) / 2 * chh, cw, chh)
          spr.ox = cw / 2
          spr.oy = chh
          dx = fx - l[0]
          dy = fy - l[1]
          dist = Math.sqrt(dx * dx + dy * dy)
          lh = l[8] ? 40.0 : (l[2] > 160.0 ? 96.0 : 64.0)    # light height
          oh = chh * 0.6
          len = oh * dist / ((lh - oh * 0.5) > 16.0 ? (lh - oh * 0.5) : 16.0) / chh
          len = 1.4 if len > 1.4
          # very short shadows read as a black bar: keep a sane minimum and
          # fade them out instead
          squash = len < 0.5 ? len / 0.5 : 1.0
          len = 0.5 if len < 0.5
          spr.angle = Math.atan2(-dx, -dy) * 180.0 / Math::PI
          spr.zoom_y = len
          spr.zoom_x = 1.0
          spr.x = c.screen_x
          spr.y = c.screen_y - 4
          st = str > 1.0 ? 1.0 : str
          target = 255.0 * st * squash * p[:obj_shadows] * (c.opacity / 255.0) * (si == 0 ? 1.0 : 0.6)
          @shadow_op ||= {}
          cur = @shadow_op[id] || target
          cur += (target - cur) * 0.12
          @shadow_op[id] = cur
          spr.opacity = cur.round
          spr.visible = true
          seen[id] = true
        end
        n += 1
      end
      @shadows.each { |id, sp| sp.visible = false if !seen[id] && !sp.disposed? }
    end

    # Contact shadow: the soft darkening right under anything standing on the
    # ground (ambient occlusion). Present in ANY light, it is what keeps
    # characters grounded instead of floating.
    def contact_bitmap
      return @cbmp if @cbmp && !@cbmp.disposed?
      w = 44
      h = 16
      @cbmp = Bitmap.new(w, h)
      col = Color.new(0, 0, 0, 0)
      h.times do |y|
        w.times do |x|
          dx = (x - w / 2 + 0.5) / (w / 2.0)
          dy = (y - h / 2 + 0.5) / (h / 2.0)
          d = dx * dx + dy * dy
          next if d >= 1.0
          a = (1.0 - d)
          col.set(0, 0, 0, 255 * a * a)
          @cbmp.set_pixel(x, y, col)
        end
      end
      @cbmp
    end

    def update_contact(p, vp, chars)
      @contact ||= {}
      str = p[:contact]
      unless str
        @contact.each_value { |sp| sp.visible = false unless sp.disposed? }
        return
      end
      seen = {}
      n = 0
      chars.each do |c|
        break if n >= 40
        next if c.nil? || c.transparent || c.opacity < 20 || c.tile_id.to_i >= 384
        next if c.is_a?(Game_Event) && c.instance_variable_get(:@through)
        name = c.character_name.to_s
        next if name.empty? || name =~ /water_waves|sparkle|glitch|lightmap|portal_rays|tv_light|door|items|paper|book|rug|crater|arrows|marimo|clover|pool/
        bmp = (RPG::Cache.character(name, c.character_hue) rescue nil)
        next unless bmp && bmp.height / 4 >= 36
        spr = @contact[c.object_id]
        if spr.nil? || spr.disposed?
          spr = Sprite.new(vp)
          spr.bitmap = contact_bitmap
          spr.ox = 22
          spr.oy = 8
          spr.z = 1
          @contact[c.object_id] = spr
        end
        cw = bmp.width / 4
        spr.zoom_x = cw / 32.0
        spr.x = c.screen_x
        spr.y = c.screen_y - 3
        spr.opacity = 255 * str * (c.opacity / 255.0)
        spr.visible = true
        seen[c.object_id] = true
        n += 1
      end
      @contact.each { |id, sp| sp.visible = false if !seen[id] && !sp.disposed? }
    end

    def hide_reflections
      (@refl || {}).each_value { |s| s.visible = false unless s.disposed? }
      (@shadows || {}).each_value { |s| s.visible = false unless s.disposed? }
      (@contact || {}).each_value { |s| s.visible = false unless s.disposed? }
    rescue StandardError
    end

    def reset_objects
      # Sprite_Character restores their opacity on its next update by itself
      (@lit_sprites || {}).each_value { |s| s.opacity = 255 unless s.disposed? }
      @lit_sprites = {}
      @lit = {}
      hide_reflections
    rescue StandardError
    end

    def hide
      reset_objects if @lit_sprites && !@lit_sprites.empty?
      hide_reflections
      @vp.visible = false if @vp && !@vp.disposed?
      @stat_spr.visible = false if @stat_spr && !@stat_spr.disposed?
    end

    def update_stats(p)
      unless @stats
        @stat_spr.visible = false if @stat_spr
        return
      end
      if @stat_spr.nil? || @stat_spr.disposed?
        @stat_spr = Sprite.new
        @stat_spr.bitmap = Bitmap.new(300, 132)
        @stat_spr.x = 640 - 304
        @stat_spr.y = 4
        @stat_spr.z = 30000
      end
      @stat_spr.visible = true
      return unless @frame % 15 == 0
      fps = 0
      now = Time.now
      if @fps_t
        dt = now - @fps_t
        fps = dt > 0 ? (@frame - @fps_f) / dt : 0
      end
      @fps_t = now
      @fps_f = @frame
      mats = Hash.new(0)
      (@mat || []).each { |m| mats[m] += 1 }
      top = mats.sort_by { |_, c| -c }[0, 3].map { |m, c| "#{m} #{c}" }.join(", ")
      lines = [
        "DEBUG  RayTrace2D #{VERSION}",
        sprintf("%s  %.1f ms/pass  every %d frames  ~%d fps", p[:name], @ms, p[:every] + @extra_every, fps.round),
        sprintf("lights %d  bounce %s  emissive tiles %d", @nlights,
                p[:pt] ? "path traced" : (@nvpl || 0).to_s, (@emissive || []).size),
        sprintf("painted shadows: tiles %d  sprite pieces %d", (@bshadow || {}).size, (@eshadow || {}).size),
        "materials: " + top,
        sprintf("map %d  Niko %d,%d  darkness x%.2f", $game_map.map_id, $game_player.x, $game_player.y, @dark_scale || 1.0),
      ]
      b = @stat_spr.bitmap
      b.clear
      b.fill_rect(b.rect, Color.new(0, 0, 0, 165))
      b.font.size = 14
      lines.each_with_index { |l, i| b.draw_text(6, 2 + i * 21, 290, 20, l) }
    end

    #--------------------------------------------------------------------------
    # HOME menu
    #--------------------------------------------------------------------------
    def btn(name, fallback)
      Input.const_defined?(name) ? Input.const_get(name) : Input.const_get(fallback)
    end

    def se(kind)
      $game_system.se_play(kind == :ok ? $data_system.decision_se : $data_system.cursor_se)
    rescue StandardError
    end

    #--------------------------------------------------------------------------
    # Language: English original / Russian official / Russian improved
    #--------------------------------------------------------------------------
    LANG_MODES = [:en, :ru, :ru_custom]
    attr_reader :lang_mode

    def ru_ui?
      ($persistent.langcode.to_s.start_with?("ru") rescue false)
    end

    def cur_lang
      return :en unless ru_ui?
      @lang_mode == :ru_custom ? :ru_custom : :ru
    end

    def lang_label
      case cur_lang
      when :ru then "\u0420\u0443\u0441\u0441\u043A\u0438\u0439 (\u043E\u0444\u0438\u0446\u0438\u0430\u043B\u044C\u043D\u044B\u0439)"
      when :ru_custom then "\u0420\u0443\u0441\u0441\u043A\u0438\u0439 (\u0443\u043B\u0443\u0447\u0448\u0435\u043D\u043D\u044B\u0439)"
      else "English (original)"
      end
    end

    def set_language(mode)
      @lang_mode = mode
      save_cfg
      # Language.set reloads the text; our load_pot hook swaps in the
      # improved Russian file when that mode is chosen
      $persistent.lang = (mode == :en ? "en" : "ru")
      $persistent.save rescue nil
      log("language -> #{mode}")
    rescue StandardError => e
      log("language change failed: #{e.class}: #{e.message}")
    end

    RU_UI = {
      "RAY TRACING 2D" => "\u0422\u0420\u0410\u0421\u0421\u0418\u0420\u041E\u0412\u041A\u0410 \u041B\u0423\u0427\u0415\u0419 2D",
      "real-time ray traced light & shadow" => "\u0441\u0432\u0435\u0442 \u0438 \u0442\u0435\u043D\u0438 \u0432 \u0440\u0435\u0430\u043B\u044C\u043D\u043E\u043C \u0432\u0440\u0435\u043C\u0435\u043D\u0438",
      "Off" => "\u0412\u044B\u043A\u043B\u044E\u0447\u0435\u043D\u043E", "Cozy (Low)" => "\u0423\u044E\u0442\u043D\u044B\u0439 (\u0441\u043B\u0430\u0431\u044B\u0439 \u041F\u041A)",
      "Game Style RT" => "\u0418\u0433\u0440\u043E\u0432\u043E\u0439 RT", "Ultra RT" => "\u0423\u043B\u044C\u0442\u0440\u0430 RT",
      "Pixel Raw" => "\u041F\u0438\u043A\u0441\u0435\u043B\u044C\u043D\u044B\u0439", "Neon Dream" => "\u041D\u0435\u043E\u043D\u043E\u0432\u044B\u0439 \u0441\u043E\u043D",
      "RTX Realistic" => "RTX \u0420\u0435\u0430\u043B\u0438\u0437\u043C", "RTX Path Traced" => "RTX \u0422\u0440\u0430\u0441\u0441\u0438\u0440\u043E\u0432\u043A\u0430 \u043F\u0443\u0442\u0435\u0439",
      "Cinematic Soft" => "\u041A\u0438\u043D\u043E (\u043C\u044F\u0433\u043A\u0438\u0439)", "HDR Classic" => "HDR \u041A\u043B\u0430\u0441\u0441\u0438\u043A\u0430",
      "Path Tracing" => "\u0422\u0440\u0430\u0441\u0441\u0438\u0440\u043E\u0432\u043A\u0430 \u043F\u0443\u0442\u0435\u0439", "Path Tracing HQ" => "\u0422\u0440\u0430\u0441\u0441\u0438\u0440\u043E\u0432\u043A\u0430 \u043F\u0443\u0442\u0435\u0439 HQ",
      "RT Reflections" => "RT \u041E\u0442\u0440\u0430\u0436\u0435\u043D\u0438\u044F", "ULTIMATE (All RTX)" => "\u0423\u041B\u042C\u0422\u0418\u041C\u0410\u0422 (\u0432\u0441\u0451 RTX)",
      "Debug mode" => "\u0420\u0435\u0436\u0438\u043C \u043E\u0442\u043B\u0430\u0434\u043A\u0438", "Performance stats" => "\u0421\u0442\u0430\u0442\u0438\u0441\u0442\u0438\u043A\u0430", "WASD movement" => "\u0425\u043E\u0434\u044C\u0431\u0430 \u043D\u0430 WASD",
      "Language" => "\u042F\u0437\u044B\u043A", "Close" => "\u0417\u0430\u043A\u0440\u044B\u0442\u044C", "[on]" => "[\u0432\u043A\u043B]", "[off]" => "[\u0432\u044B\u043A\u043B]",
      "Z: choose   X / Home / Alt: close" => "Z: \u0432\u044B\u0431\u0440\u0430\u0442\u044C   X / Home / Alt: \u0437\u0430\u043A\u0440\u044B\u0442\u044C",
      "Z: choose   X / Home: close" => "Z: \u0432\u044B\u0431\u0440\u0430\u0442\u044C   X / Home: \u0437\u0430\u043A\u0440\u044B\u0442\u044C",
      "Vanilla OneShot lighting." => "\u041E\u0431\u044B\u0447\u043D\u043E\u0435 \u043E\u0441\u0432\u0435\u0449\u0435\u043D\u0438\u0435 OneShot.",
      "Big soft cells, light on the CPU." => "\u041A\u0440\u0443\u043F\u043D\u044B\u0435 \u043C\u044F\u0433\u043A\u0438\u0435 \u044F\u0447\u0435\u0439\u043A\u0438, \u043B\u0451\u0433\u043A\u0438\u0439 \u0434\u043B\u044F \u041F\u041A.",
      "Smooth ray traced shadows, subtle glow." => "\u0413\u043B\u0430\u0434\u043A\u0438\u0435 \u0442\u0440\u0430\u0441\u0441\u0438\u0440\u043E\u0432\u0430\u043D\u043D\u044B\u0435 \u0442\u0435\u043D\u0438.",
      "Soft area shadows + bounce light." => "\u041C\u044F\u0433\u043A\u0438\u0435 \u0442\u0435\u043D\u0438 + \u043E\u0442\u0440\u0430\u0436\u0451\u043D\u043D\u044B\u0439 \u0441\u0432\u0435\u0442.",
      "No blur. Crunchy retro shadows." => "\u0411\u0435\u0437 \u0440\u0430\u0437\u043C\u044B\u0442\u0438\u044F. \u0425\u0440\u0443\u0441\u0442\u044F\u0449\u0438\u0435 \u0440\u0435\u0442\u0440\u043E-\u0442\u0435\u043D\u0438.",
      "Rainbow-shifting colored lights." => "\u041F\u0435\u0440\u0435\u043B\u0438\u0432\u0430\u044E\u0449\u0438\u0435\u0441\u044F \u0446\u0432\u0435\u0442\u043D\u044B\u0435 \u043E\u0433\u043D\u0438.",
      "Bounce light, AO, emissives, filmic HDR." => "\u041E\u0442\u0441\u043A\u043E\u043A\u0438 \u0441\u0432\u0435\u0442\u0430, AO, \u0441\u0432\u0435\u0447\u0435\u043D\u0438\u0435, HDR.",
      "Max: shadowed bounces, 5-ray soft shadows." => "\u041C\u0430\u043A\u0441\u0438\u043C\u0443\u043C: \u0442\u0435\u043D\u0438 \u043E\u0442\u0441\u043A\u043E\u043A\u043E\u0432, 5 \u043B\u0443\u0447\u0435\u0439.",
      "Eye-friendly: low contrast, warm, calm." => "\u0411\u0435\u0440\u0435\u0436\u0451\u0442 \u0433\u043B\u0430\u0437\u0430: \u043C\u044F\u0433\u043A\u043E \u0438 \u0442\u0435\u043F\u043B\u043E.",
      "2004 HDR look: bloom + eye adaptation." => "HDR \u043A\u0430\u043A \u0432 2004: \u0441\u0432\u0435\u0447\u0435\u043D\u0438\u0435 + \u0430\u0434\u0430\u043F\u0442\u0430\u0446\u0438\u044F.",
      "Real Monte Carlo GI, 1 bounce, converges." => "\u041D\u0430\u0441\u0442\u043E\u044F\u0449\u0438\u0439 \u041C\u043E\u043D\u0442\u0435-\u041A\u0430\u0440\u043B\u043E GI, 1 \u043E\u0442\u0441\u043A\u043E\u043A.",
      "2 rays/cell, 2 bounces, 5-ray shadows." => "2 \u043B\u0443\u0447\u0430, 2 \u043E\u0442\u0441\u043A\u043E\u043A\u0430, \u0442\u0435\u043D\u0438 \u0438\u0437 5 \u043B\u0443\u0447\u0435\u0439.",
      "Mirror floors, water, metal sheen." => "\u0417\u0435\u0440\u043A\u0430\u043B\u044C\u043D\u044B\u0435 \u043F\u043E\u043B\u044B, \u0432\u043E\u0434\u0430, \u0431\u043B\u0435\u0441\u043A \u043C\u0435\u0442\u0430\u043B\u043B\u0430.",
      "Path tracing+reflections+materials+all." => "\u0422\u0440\u0430\u0441\u0441\u0438\u0440\u043E\u0432\u043A\u0430 \u043F\u0443\u0442\u0435\u0439 + \u043E\u0442\u0440\u0430\u0436\u0435\u043D\u0438\u044F + \u0432\u0441\u0451.",
      "Live info: speed, lights, shadows, materials." => "\u0421\u043A\u043E\u0440\u043E\u0441\u0442\u044C, \u0441\u0432\u0435\u0442, \u0442\u0435\u043D\u0438, \u043C\u0430\u0442\u0435\u0440\u0438\u0430\u043B\u044B.",
      "Shows ms per ray trace pass." => "\u041F\u043E\u043A\u0430\u0437\u044B\u0432\u0430\u0435\u0442 \u043C\u0441 \u043D\u0430 \u043F\u0440\u043E\u0445\u043E\u0434 \u0442\u0440\u0430\u0441\u0441\u0438\u0440\u043E\u0432\u043A\u0438.",
      "WASD walks. Main menu: Q, items: E." => "WASD = \u0445\u043E\u0434\u044C\u0431\u0430. \u041C\u0435\u043D\u044E: Q, \u043F\u0440\u0435\u0434\u043C\u0435\u0442\u044B: E.",
      "Left/right or Z: switch language." => "\u0412\u043B\u0435\u0432\u043E/\u0432\u043F\u0440\u0430\u0432\u043E \u0438\u043B\u0438 Z: \u0441\u043C\u0435\u043D\u0438\u0442\u044C \u044F\u0437\u044B\u043A.",
    }

    def t(str)
      ru_ui? ? (RU_UI[str] || str) : str
    end

    def menu_items
      PRESETS.map { |p| p[:name] } + ["Debug mode", "WASD movement", "Language", "Close"]
    end

    def open_menu
      @in_menu = true
      items = menu_items
      np = PRESETS.size
      idx = @preset
      spr = Sprite.new
      spr.z = 30000
      spr.bitmap = Bitmap.new(410, 60 + items.size * 20 + 42)
      spr.x = (640 - spr.bitmap.width) / 2
      spr.y = (480 - spr.bitmap.height) / 2
      draw_menu(spr.bitmap, items, idx)
      up = btn(:UP, :UP); down = btn(:DOWN, :DOWN)
      left = btn(:LEFT, :LEFT); right = btn(:RIGHT, :RIGHT)
      ok = btn(:ACTION, :C); cancel = btn(:CANCEL, :B)
      60.times do
        Graphics.rt2d_orig_update
        break unless key?(raw_keys, KEY_HOME) || key?(raw_keys, KEY_F8)
      end
      @prev_key = false
      Input.update
      loop do
        Graphics.rt2d_orig_update
        Input.update
        break if Input.respond_to?(:quit?) && Input.quit?
        break if toggle_pressed? || Input.trigger?(cancel)
        if Input.repeat?(up)
          idx = (idx - 1) % items.size; se(:cursor); draw_menu(spr.bitmap, items, idx)
        elsif Input.repeat?(down)
          idx = (idx + 1) % items.size; se(:cursor); draw_menu(spr.bitmap, items, idx)
        elsif idx == np + 2 && (Input.trigger?(left) || Input.trigger?(right) || Input.trigger?(ok))
          se(:ok)
          step = Input.trigger?(left) ? -1 : 1
          set_language(LANG_MODES[((LANG_MODES.index(cur_lang) || 0) + step) % LANG_MODES.size])
          draw_menu(spr.bitmap, items, idx)
        elsif Input.trigger?(ok)
          se(:ok)
          if idx < np
            @preset = idx
            @extra_every = 0
            @prev_acc = nil
            @pt_buf = nil
            @expo = 1.0
            save_cfg
            log("preset -> #{PRESETS[idx][:name]}")
            if PRESETS[idx][:cell]
              ensure_layers
              refresh(PRESETS[idx])
              place_layers
            else
              hide
            end
          elsif idx == np
            @stats = !@stats
            save_cfg
          elsif idx == np + 1
            @wasd = !wasd_on?
            save_cfg
          else
            break
          end
          draw_menu(spr.bitmap, items, idx)
        end
      end
    ensure
      if spr
        spr.bitmap.dispose
        spr.dispose
      end
      Input.update rescue nil
      @next_refresh = 0
      @in_menu = false
    end

    # gradient_fill_rect is missing on this engine -> draw gradients as 2px strips
    def grad(b, x, y, w, h, c1, c2, vertical = false)
      len = vertical ? h : w
      steps = [len / 2, 1].max
      steps.times do |k|
        tt = steps > 1 ? k.to_f / (steps - 1) : 0.0
        c = Color.new(c1.red + (c2.red - c1.red) * tt, c1.green + (c2.green - c1.green) * tt,
                      c1.blue + (c2.blue - c1.blue) * tt, c1.alpha + (c2.alpha - c1.alpha) * tt)
        if vertical
          b.fill_rect(x, y + k * 2, w, 2, c)
        else
          b.fill_rect(x + k * 2, y, 2, h, c)
        end
      end
    end

    def draw_menu(b, items, idx)
      b.clear
      w = b.width
      h = b.height
      np = PRESETS.size
      b.fill_rect(0, 0, w, h, Color.new(255, 210, 120, 220))
      b.fill_rect(2, 2, w - 4, h - 4, Color.new(14, 10, 28, 235))
      grad(b, 2, 2, w - 4, 50, Color.new(80, 50, 10, 255), Color.new(20, 20, 70, 255))
      b.font.size = 24
      b.font.color = Color.new(255, 225, 140)
      b.draw_text(0, 5, w, 28, t("RAY TRACING 2D"), 1)
      b.font.size = 14
      b.font.color = Color.new(200, 200, 255)
      b.draw_text(0, 30, w, 18, t("real-time ray traced light & shadow") + "  v#{VERSION}", 1)
      b.font.size = 17
      items.each_with_index do |name, i|
        y = 56 + i * 20
        grad(b, 10, y, w - 20, 19, Color.new(255, 190, 90, 200), Color.new(255, 120, 200, 60)) if i == idx
        active = (i == @preset) || (i == np && @stats) || (i == np + 1 && wasd_on?)
        b.font.color = active ? Color.new(255, 235, 150) : Color.new(235, 235, 245)
        label = t(name)
        label += "  " + t(@stats ? "[on]" : "[off]") if i == np
        label += "  " + t(wasd_on? ? "[on]" : "[off]") if i == np + 1
        label += ":  < " + lang_label + " >" if i == np + 2
        b.draw_text(22, y - 2, w - 60, 22, label)
        b.draw_text(w - 44, y - 2, 24, 22, "*", 1) if i == @preset
      end
      b.font.size = 14
      b.font.color = Color.new(190, 190, 210)
      desc = if idx < np then PRESETS[idx][:desc]
             elsif idx == np then "Live info: speed, lights, shadows, materials."
             elsif idx == np + 1 then "WASD walks. Main menu: Q, items: E."
             elsif idx == np + 2 then "Left/right or Z: switch language."
             else ""
             end
      b.draw_text(12, h - 38, w - 24, 18, t(desc), 1)
      b.draw_text(12, h - 20, w - 24, 18, t("Z: choose   X / Home / Alt: close"), 1)
    end

    #--------------------------------------------------------------------------
    # WASD movement. W/A/S/D act as the arrow keys (arrows still work). The
    # old A (main menu), S (items) and W (hold-to-skip) actions move to Q, E
    # and R. What each letter originally did is also learned at runtime, so a
    # custom F1 binding is respected.
    #--------------------------------------------------------------------------
    KEY_W = 26; KEY_A = 4; KEY_S = 22; KEY_D = 7
    KEY_Q = 20; KEY_E = 8; KEY_R = 21
    LETTERS = [KEY_W, KEY_A, KEY_S, KEY_D]

    def wasd_on?
      @wasd != false
    end

    def input_init
      dirs = [Input::UP, Input::DOWN, Input::LEFT, Input::RIGHT]
      @dirk = { Input::UP => KEY_W, Input::LEFT => KEY_A, Input::DOWN => KEY_S, Input::RIGHT => KEY_D }
      skip = [:ACTION, :CANCEL, :RUN, :C, :B]
      @btns = Input.constants.map { |c|
        v = Input.const_get(c)
        (v.is_a?(Integer) && !skip.include?(c) && !dirs.include?(v)) ? v : nil
      }.compact.uniq
      cm = Input.const_defined?(:MENU) ? [Input::MENU] : []
      ci = Input.const_defined?(:ITEMS) ? [Input::ITEMS] : []
      cr = Input.const_defined?(:R) ? [Input::R] : []
      @learn = { KEY_A => cm, KEY_S => ci, KEY_W => cr, KEY_D => [] }
      @moved = { KEY_Q => KEY_A, KEY_E => KEY_S, KEY_R => KEY_W }
      @kcur = {}
      @kprev = {}
      @khold = Hash.new(0)
    end

    def input_poll
      return unless @dirk
      @kprev = @kcur
      st = raw_keys
      @kcur = {}
      [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E, KEY_R].each do |sc|
        d = key?(st, sc)
        @kcur[sc] = d
        @khold[sc] = d ? @khold[sc] + 1 : 0
      end
      held = LETTERS.select { |sc| @kcur[sc] }
      if held.size == 1 && @khold[held[0]] == 2 && !@kcur[KEY_Q] && !@kcur[KEY_E] && !@kcur[KEY_R]
        sc = held[0]
        @btns.each { |b| @learn[sc] << b if !@learn[sc].include?(b) && Input.rt2d_press(b) }
      end
    end

    def k_state(mode, sc)
      case mode
      when :press then @kcur[sc]
      when :trigger then @kcur[sc] && !@kprev[sc]
      else
        hh = @khold[sc]
        hh == 1 || (hh > 16 && (hh - 16) % 5 == 0)
      end
    end

    def in_btn(mode, b, v)
      return v unless wasd_on? && @dirk && !@kcur.empty?
      if (sc = @dirk[b])
        return v || !!k_state(mode, sc)
      end
      v = false if v && LETTERS.any? { |l| @kcur[l] && @learn[l].include?(b) }
      @moved.each do |nk, old|
        return true if @learn[old].include?(b) && k_state(mode, nk)
      end
      v
    rescue StandardError
      v
    end

    def in_dir4(v)
      return v unless v == 0 && wasd_on? && @dirk && !@kcur.empty?
      best = 0
      bh = nil
      @dirk.each do |b, sc|
        hh = @khold[sc]
        if hh > 0 && (bh.nil? || hh < bh)
          bh = hh
          best = b
        end
      end
      best
    rescue StandardError
      v
    end

    def in_dir8(v)
      return v unless v == 0 && wasd_on? && @dirk && !@kcur.empty?
      u = @kcur[KEY_W]; d = @kcur[KEY_S]; l = @kcur[KEY_A]; r = @kcur[KEY_D]
      y = (u && !d) ? 8 : ((d && !u) ? 2 : 5)
      x = (l && !r) ? -1 : ((r && !l) ? 1 : 0)
      return 0 if y == 5 && x == 0
      y + x
    rescue StandardError
      v
    end

    #--------------------------------------------------------------------------
    # TEST TOUR (only while Mods/teleport.txt exists; used for screenshots).
    # The file holds a map id; whenever it changes, Niko is moved there and
    # placed on a walkable tile near the middle of the map.
    #--------------------------------------------------------------------------
    TOUR = DIR + "/teleport.txt"

    def tour_init
      @tour_on = File.exist?(TOUR)
      return unless @tour_on
      # never touch the real desktop / external programs while touring
      if defined?(::Wallpaper)
        class << ::Wallpaper
          [:set, :reset, :set_persistent, :reset_persistent].each { |m| define_method(m) { |*a| nil } }
        end
      end
      if defined?(::Journal)
        class << ::Journal
          define_method(:set) { |*a| nil }
        end
      end
      @nounshadow = File.exist?(DIR + "/nounshadow.flag")
      log("TOUR mode on#{@nounshadow ? ' (shadow lifting OFF for comparison)' : ''}")
      engine_probe if File.exist?(DIR + "/probe.flag")
    end

    # TEST ONLY: log which Input buttons each letter key triggers
    def key_probe
      st = raw_keys
      { "W" => 26, "A" => 4, "S" => 22, "D" => 7, "Q" => 20, "E" => 8 }.each do |nm, sc|
        down = key?(st, sc)
        if down && !(@probe_prev ||= {})[nm]
          hits = Input.constants.select { |c| v = Input.const_get(c); v.is_a?(Integer) && (Input.press?(v) rescue false) }
          log("KEYPROBE #{nm}: #{hits.inspect}")
        end
        @probe_prev[nm] = down
      end
    end

    # What the engine REALLY exposes (RGSS1 mode hides many functions)
    def engine_probe
      r = []
      r << "snap_to_bitmap=#{Graphics.respond_to?(:snap_to_bitmap)}"
      r << "smooth=#{Graphics.respond_to?(:smooth=)}"
      b = Bitmap.new(4, 1)
      %w[blur radial_blur clear_rect gradient_fill_rect].each { |m| r << "#{m}=#{b.respond_to?(m)}" }
      sp = Sprite.new
      %w[wave_amp= bush_opacity= obscured=].each { |m| r << "sprite.#{m}=#{sp.respond_to?(m)}" }
      sp.dispose
      fid = begin
              require('fiddle') ? 'yes' : 'yes'
            rescue LoadError, StandardError
              'no'
            end
      r << "Fiddle=#{fid}"
      r << "Win32API=#{defined?(Win32API) ? 'yes' : 'no'}"
      # is stretch_blt smooth (linear) or blocky (nearest)?
      b.set_pixel(0, 0, Color.new(0, 0, 0)); b.set_pixel(1, 0, Color.new(255, 255, 255))
      big = Bitmap.new(64, 1)
      big.stretch_blt(big.rect, b, Rect.new(0, 0, 2, 1))
      r << "stretch_mid=#{big.get_pixel(31, 0).red.round} (nearest=0/255, linear=~128)"
      big.dispose
      b.dispose
      begin
        snap = Graphics.snap_to_bitmap
        r << "snap_works=#{snap.width}x#{snap.height}"
        snap.dispose
      rescue Exception => e
        r << "snap_error=#{e.class}"
      end
      log("ENGINE PROBE: " + r.join(" "))
    rescue Exception => e
      log("engine probe failed: #{e.class}: #{e.message}")
    end

    def test_tour
      key_probe if File.exist?(DIR + "/keyprobe.flag")
      return unless map_ready? && (@frame % 20 == 0 || @tour_phase == :place)
      raw = (File.read(TOUR).strip rescue "0")
      id, @tour_x, @tour_y = raw.split(":").map(&:to_i)
      id ||= 0
      if id > 0 && id != @tour_id && !$game_temp.player_transferring
        @tour_id = id
        # the sun bulb for the tour (not in the start room: test Niko's eyes there)
        $game_party.gain_item(1, 1) if $game_party.item_number(1) == 0 && id != 2 rescue nil
        $game_temp.player_new_map_id = id
        $game_temp.player_new_x = 1
        $game_temp.player_new_y = 1
        $game_temp.player_new_direction = 2
        $game_temp.player_transferring = true
        @tour_phase = :place
        return
      end
      if @tour_phase == :place && $game_map.map_id == @tour_id && !$game_temp.player_transferring
        cx = $game_map.width / 2
        cy = $game_map.height / 2
        best = nil
        r = 0
        while r < 40 && best.nil?
          (-r..r).each do |dy|
            (-r..r).each do |dx|
              next unless dx.abs == r || dy.abs == r
              x = cx + dx; y = cy + dy
              next if x < 1 || y < 1 || x >= $game_map.width - 1 || y >= $game_map.height - 1
              if [2, 4, 6, 8].all? { |d| $game_map.passable?(x, y, d) } && !solid?(x, y)
                best = [x, y]; break
              end
            end
            break if best
          end
          r += 1
        end
        best ||= [cx, cy]
        best = [@tour_x, @tour_y] if @tour_x && @tour_y && @tour_x > 0
        $game_player.moveto(best[0], best[1])
        @tour_phase = nil
        log("TOUR map #{@tour_id} (#{$game_map.tileset_name}) at #{best.inspect} " +
            "size #{$game_map.width}x#{$game_map.height}")
      end
    rescue StandardError => e
      log("tour error: #{e.class}: #{e.message}")
      @tour_phase = nil
    end

    #--------------------------------------------------------------------------
    # Self test (only when Mods/selftest.flag exists) -- exercises engine APIs
    #--------------------------------------------------------------------------
    def selftest
      log("selftest: start")
      saved = [@solid, @mw, @mh, @map_key]
      @mw = 30; @mh = 20
      @solid = "\0" * (@mw * @mh)
      (5..15).each { |y| @solid.setbyte(12 + y * @mw, 1) }   # a vertical wall
      PRESETS.each do |p|
        next unless p[:cell]
        cell = p[:cell]
        gw = 640 / cell + 3
        gh = 480 / cell + 3
        lights = [[300.0, 300.0, 210.0, 1.0, 0.86, 0.55, 1.15, 0.0],
                  [500.0, 200.0, 120.0, 0.5, 0.8, 1.0, 0.8, 0.0]]
        t0 = Time.now
        acc = trace_grid(p, -cell, -cell, gw, gh, lights)
        t1 = Time.now
        ensure_layers
        render(p, gw, gh, acc)
        t2 = Time.now
        # cell left of the wall (lit) vs right of the wall (shadowed by light 1)
        lit = acc[0][(300 / cell + 1) + (300 / cell + 1) * gw]
        shadow = acc[0][(440 / cell + 1) + (300 / cell + 1) * gw]
        log(sprintf("selftest: %-14s trace %.1f ms, render %.1f ms, lit=%.2f behind-wall=%.2f",
                    p[:name], (t1 - t0) * 1000, (t2 - t1) * 1000, lit, shadow))
      end
      hide
      log("selftest: OK")
    rescue StandardError => e
      log("selftest FAILED: #{e.class}: #{e.message}\n  " + (e.backtrace || [])[0, 6].join("\n  "))
    ensure
      @solid, @mw, @mh, @map_key = saved if saved
    end
  end
end

#------------------------------------------------------------------------------
# Hook: run the lighting once per frame, before the engine draws it
#------------------------------------------------------------------------------
begin
  module Graphics
    class << self
      alias_method :rt2d_orig_update, :update
      def update
        begin
          RT2D.frame
        rescue StandardError => e
          RT2D.fail(e)
        end
        rt2d_orig_update
      end
    end
  end
  RT2D.boot
rescue StandardError => e
  RT2D.log("boot failed: #{e.class}: #{e.message}") rescue nil
end

# WASD: wrap the engine's Input functions (arrows keep working)
begin
  RT2D.input_init
  class << Input
    alias_method :rt2d_update, :update
    alias_method :rt2d_press, :press?
    alias_method :rt2d_trigger, :trigger?
    alias_method :rt2d_repeat, :repeat?
    alias_method :rt2d_dir4, :dir4
    alias_method :rt2d_dir8, :dir8
    def update
      rt2d_update
      begin
        RT2D.input_poll
      rescue StandardError
      end
    end
    def press?(b);   RT2D.in_btn(:press, b, rt2d_press(b));     end
    def trigger?(b); RT2D.in_btn(:trigger, b, rt2d_trigger(b)); end
    def repeat?(b);  RT2D.in_btn(:repeat, b, rt2d_repeat(b));   end
    def dir4;        RT2D.in_dir4(rt2d_dir4);                   end
    def dir8;        RT2D.in_dir8(rt2d_dir8);                   end
  end
rescue StandardError => e
  RT2D.log("WASD setup failed: #{e.class}: #{e.message}") rescue nil
end

# Improved Russian: when chosen, the official ru.po is swapped for ours
# (lines we have not rewritten fall back to the official text inside it)
begin
  if defined?(::Language)
    class << ::Language
      alias_method :rt2d_load_pot, :load_pot
      def load_pot(path)
        if RT2D.lang_mode == :ru_custom && path.to_s =~ /Languages\/ru\.po\z/ && File.exist?(RT2D::RU_CUSTOM)
          path = RT2D::RU_CUSTOM
        end
        rt2d_load_pot(path)
      end
    end
  end
rescue StandardError => e
  RT2D.log("boot failed: #{e.class}: #{e.message}") rescue nil
end
