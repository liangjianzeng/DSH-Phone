import 'dart:math' as math;

/// 观测者位置（大地坐标，度）。纬度北纬为正、经度东经为正。
class ObserverLocation {
  const ObserverLocation(this.latitude, this.longitude);

  /// 纬度（北纬为正，度）。
  final double latitude;

  /// 经度（东经为正，度）。
  final double longitude;
}

/// 月球观测形态快照：相位、照明度、明暗界线在盘面上的倾角。
class MoonObservation {
  const MoonObservation({
    required this.phase01,
    required this.illumination,
    required this.tiltDeg,
    required this.name,
  });

  /// 月相 0..1：0=朔(新月)，0.5=望(满月)，1=朔(新月)。小时级连续变化。
  final double phase01;

  /// 照明度 0..1（真实余弦模型）。
  final double illumination;

  /// 明暗界线相对盘面「垂直向上」的倾角（度）。正 = 盘面上逆时针。
  /// 由「亮缘位置角 PA」与「地平纬角（天顶方向在盘面上的投影角）」合成，
  /// 包含观测纬度与月球时角（经度/时刻）的影响——月出月落的旋转效应。
  final double tiltDeg;

  /// 八相名称（朔/娥眉/上弦/盈凸/望/亏凸/下弦/残月）。
  final String name;
}

/// 真实月球观测计算（Meeus《Astronomical Algorithms》低-中精度算法）。
///
/// 月球不发光，我们看到的形态由三个要素决定：
/// 1. **照明度**：日-地-月相位角 ψ 的余弦模型 k=(1−cos ψ)/2，随绝对时间
///    连续变化（朔望周期 29.53 天）——不是农历日粒度的近似。
/// 2. **亮缘朝向**：亮缘永远指向太阳在天空的方向，其相对天北的位置角 PA
///    由日月坐标计算。
/// 3. **地平旋转**：观测者看到的「竖直」是向天顶方向，而天北方向在月球
///    所在天空位置上的投影与竖直的夹角（地平纬角 q）随观测纬度 φ 与
///    月球时角（经度与时区决定本地时刻）变化——这就是月出月落时亮面
///    旋转、以及高纬度/南半球形态不同的根源。
class MoonAstronomy {
  MoonAstronomy._();

  /// 由绝对时间（UTC）与观测者位置计算月球观测形态。
  static MoonObservation compute(DateTime nowUtc, ObserverLocation observer) {
    final jd = _julianDate(nowUtc);
    final t = (jd - 2451545.0) / 36525.0;

    // 太阳与月球的地心坐标（赤经/赤纬/黄道经度）。
    final sun = _sunEquatorial(t); // (ra, dec, λsun)
    final moonGeo = _moonEquatorial(t); // (ra, dec, dist, λmoon)

    // 月相 0..1：月球相对太阳的黄经差归一化（0=朔、0.5=望、→1 回朔）。
    // 这才是朔望周期的正确相位，小时级连续。
    final phase01 = _normDeg(moonGeo.$4 - sun.$3) / 360.0;

    // 月球视差（地平视差 p），用于地心→站心的顶心修正（月球近，~1°）。
    final distanceKm = moonGeo.$3;
    final hp = _horParallax(distanceKm);

    // 站心（顶心）月球赤经/赤纬。
    final lstDeg = _localSiderealDeg(jd, observer.longitude);
    final moonTopo = _topocentric(
        moonGeo.$1, moonGeo.$2, hp, lstDeg, observer.latitude);

    // 相位角 ψ（月球处太阳-地球夹角）→ 照明度 k（余弦模型）。
    final cosPsi = _cosPhaseAngle(sun.$1, sun.$2, moonTopo.$1, moonTopo.$2);
    final phaseAngle = math.acos(cosPsi.clamp(-1.0, 1.0));
    final illumination = (1.0 - math.cos(phaseAngle)) / 2.0;

    // 亮缘位置角 PA（相对天北，向东为正）。
    final pa = _positionAngle(
        sun.$1, sun.$2, moonTopo.$1, moonTopo.$2);

    // 月球地平坐标（高度/方位）与地平纬角 q。
    final altAz = _altAzimuth(lstDeg, moonTopo.$1, moonTopo.$2,
        observer.latitude);
    final q = _parallacticAngle(
        altAz.$1 /*alt*/, altAz.$2 /*az*/, moonTopo.$2 /*dec*/,
        observer.latitude);

    // 盘面「竖直」（向天顶）在盘面上的位置角 PA_Z；天顶与天北在月球处
    // 夹角为 q，竖直相对天北向东偏转 q。
    final paZenith = q;

    // 明暗界线相对盘面竖直的倾角：亮缘方向 − 竖直方向。
    final tiltDeg = _normDeg(pa - paZenith);

    return MoonObservation(
      phase01: phase01,
      illumination: illumination,
      tiltDeg: tiltDeg,
      name: _phaseName(phase01),
    );
  }

  // ---------- 儒略日 / 恒星时 ----------

  static double _julianDate(DateTime utc) {
    final y = utc.year;
    final m = utc.month;
    final d = utc.day;
    final ut = utc.hour + utc.minute / 60.0 + utc.second / 3600.0;
    return 367.0 * y -
        (7 * (y + ((m + 9) ~/ 12)) ~/ 4) +
        (275 * m ~/ 9) +
        d +
        1721013.5 +
        ut / 24.0;
  }

  /// 格林尼治平恒星时（度）。
  static double _gmstDeg(double jd) {
    final t = (jd - 2451545.0) / 36525.0;
    return _normDeg(280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * t * t -
        t * t * t / 38710000.0);
  }

  /// 本地恒星时（度） = GMST + 东经经度。
  static double _localSiderealDeg(double jd, double longitudeDeg) {
    return _normDeg(_gmstDeg(jd) + longitudeDeg);
  }

  // ---------- 太阳位置（Meeus 25，低精度，~0.01°）----------

  static (double, double, double) _sunEquatorial(double t) {
    final l0 = _normDeg(280.46646 + 36000.76983 * t + 0.0003032 * t * t);
    final m = _normDeg(357.52911 + 35999.05029 * t - 0.0001537 * t * t);
    final c = (1.914602 - 0.004817 * t - 0.000014 * t * t) *
            _sinDeg(m) +
        (0.019993 - 0.000101 * t) * _sinDeg(2 * m) +
        0.000289 * _sinDeg(3 * m);
    final lambda = _normDeg(l0 + c); // 真黄道经度
    final eps = 23.439291 - 0.000004 * t;
    final ra = _atan2Deg(
        _cosDeg(eps) * _sinDeg(lambda), _cosDeg(lambda));
    final dec = _asinDeg(_sinDeg(eps) * _sinDeg(lambda));
    return (ra, dec, lambda);
  }

  // ---------- 月球位置（Meeus 47，主导项，~0.05°）----------

  static (double, double, double, double) _moonEquatorial(double t) {
    final lp = _normDeg(218.3164477 +
        481267.88123421 * t -
        0.0015786 * t * t +
        t * t * t / 538841.0);
    final d = _normDeg(297.8501921 +
        445267.1114034 * t -
        0.0018819 * t * t +
        t * t * t / 545868.0);
    final m = _normDeg(357.5291092 + 35999.0502909 * t - 0.0001536 * t * t);
    final mp = _normDeg(134.9634114 +
        477198.8676313 * t +
        0.0089970 * t * t +
        t * t * t / 69699.0);
    final f = _normDeg(93.2720993 +
        483202.0175273 * t -
        0.0034029 * t * t -
        t * t * t / 3526000.0);
    final a1 = _normDeg(119.75 + 131.849 * t);
    final a2 = _normDeg(182.25 + 119.40 * t);
    final a3 = _normDeg(15.22 + 445.267 * t);
    final e = 1.0 - 0.002516 * t - 0.0000074 * t * t;

    // 经度主导项（(d,m,mp,f) → 振幅，单位 1e-6 度）。
    const lonTerms = <List<double>>[
      [0, 0, 1, 0, 6288774],
      [2, 0, -1, 0, 1274027],
      [2, 0, 0, 0, 658314],
      [0, 0, 2, 0, 213618],
      [0, 1, 0, 0, -185116],
      [0, 0, 0, 2, -114332],
      [2, 0, -2, 0, 88897],
      [2, -1, -1, 0, -71937],
      [2, -2, 0, 0, -54016],
      [1, -1, 0, 0, -28923],
      [2, -1, 0, 0, 28895],
      [1, 0, 0, 0, -19870],
      [0, -1, 0, 0, -19331],
      [1, -2, 0, 0, -17452],
      [2, 0, 1, 0, 14985],
      [1, 1, 0, 0, -16105],
      [2, -1, 1, 0, -14235],
      [1, -2, -1, 0, -11121],
      [1, 0, 2, 0, -9247],
      [2, -2, -1, 0, -8419],
      [2, 0, 2, 0, -7521],
      [0, 1, 1, 0, -6431],
      [1, -1, 2, 0, -5925],
      [1, -1, 1, 0, -5764],
      [0, 2, 0, 0, -5252],
      [2, -1, -2, 0, -4722],
    ];
    // 纬度主导项。
    const latTerms = <List<double>>[
      [0, 0, 0, 1, 5128122],
      [0, 0, 1, 1, 280602],
      [0, 0, 1, -1, 277693],
      [2, 0, 0, -1, 173237],
      [2, 0, -1, 1, 55413],
      [2, -1, 0, 1, -32601],
      [1, -1, 0, 1, -16733],
      [2, -2, 0, 1, -10575],
      [0, 1, 1, 1, 11695],
      [0, 1, 1, -1, -11122],
      [1, 0, 0, 1, -10875],
      [0, 0, 0, 3, -10875],
      [1, -1, 1, 1, 10814],
      [2, 0, -2, 1, 10466],
      [0, 0, 2, 1, 10317],
      [0, 0, 2, -1, 10317],
      [1, -2, 0, 1, -9205],
    ];
    // 距离主导项（单位 km）。
    const distTerms = <List<double>>[
      [0, 0, 1, 0, 20973355],
      [2, 0, -1, 0, 3703685],
      [2, 0, 0, 0, 2493957],
      [0, 0, 2, 0, 1127317],
      [0, 1, 0, 0, 855063],
      [0, 0, 0, 2, 617240],
      [2, 0, -2, 0, 470055],
      [2, -1, -1, 0, 342610],
      [2, -2, 0, 0, 261960],
      [1, -1, 0, 0, 178779],
      [2, -1, 0, 0, -161784],
      [1, 0, 0, 0, 145897],
      [0, -1, 0, 0, 122045],
      [2, 0, 1, 0, 110470],
      [1, -2, 0, 0, -101049],
      [1, 1, 0, 0, 94974],
      [2, -1, 1, 0, 94307],
      [1, -2, -1, 0, 87388],
      [1, 0, 2, 0, 76244],
      [2, -2, -1, 0, 66250],
      [2, 0, 2, 0, 58978],
      [0, 1, 1, 0, 53114],
      [1, -1, 2, 0, 49530],
      [1, -1, 1, 0, 47097],
      [0, 2, 0, 0, 43903],
      [2, -1, -2, 0, 39573],
    ];

    var sumL = 0.0;
    for (final term in lonTerms) {
      final arg = term[0] * d + term[1] * m + term[2] * mp + term[3] * f;
      var amp = term[4];
      if (term[1].abs() == 1 && term[2].abs() == 1) {
        amp *= e;
      }
      sumL += amp * _sinDeg(arg);
    }
    // 经度附加项。
    sumL += 3958 * _sinDeg(a1) + 1960 * _sinDeg(lp - f) + 318 * _sinDeg(a2);

    var sumB = 0.0;
    for (final term in latTerms) {
      final arg = term[0] * d + term[1] * m + term[2] * mp + term[3] * f;
      var amp = term[4];
      if (term[1].abs() == 1 && term[2].abs() == 1) {
        amp *= e;
      }
      sumB += amp * _sinDeg(arg);
    }
    // 纬度附加项。
    sumB += -2235 * _sinDeg(lp) +
        382 * _sinDeg(a3) +
        175 * _sinDeg(a1 - f) +
        175 * _sinDeg(a1 + f) +
        127 * _sinDeg(lp - mp) -
        115 * _sinDeg(lp + mp);

    var sumR = 0.0;
    for (final term in distTerms) {
      final arg = term[0] * d + term[1] * m + term[2] * mp + term[3] * f;
      var amp = term[4];
      if (term[1].abs() == 1 && term[2].abs() == 1) {
        amp *= e;
      }
      sumR += amp * _sinDeg(arg);
    }

    // 黄道经度/纬度/距离。
    final lon = _normDeg(lp + sumL / 1e6); // 月球黄道经度
    final lat = sumB / 1e6;
    final dist = 385000.56 + sumR / 1000.0;

    // 黄道 → 赤道。
    final eps = 23.439291 - 0.000004 * t;
    final ra = _atan2Deg(_sinDeg(lon) * _cosDeg(eps) -
        _tanDeg(lat) * _sinDeg(eps), _cosDeg(lon));
    final dec = _asinDeg(_sinDeg(lat) * _cosDeg(eps) +
        _cosDeg(lat) * _sinDeg(eps) * _sinDeg(lon));
    return (ra, dec, dist, lon);
  }

  // ---------- 视差 / 顶心修正 ----------

  /// 地平视差（度）：p = asin(R_earth / d)。
  static double _horParallax(double distanceKm) {
    return _asinDeg(6378.14 / distanceKm);
  }

  /// 站心（顶心）赤经/赤纬：视差把天体抬高（alt_t = alt + p·cos(alt)），
  /// 方位角不变，再由地平坐标反算赤经/赤纬（一阶近似，月球 ~1°）。
  static (double, double) _topocentric(double raDeg, double decDeg,
      double hpDeg, double lstDeg, double latitudeDeg) {
    // 地心地平坐标。
    final geoAltAz = _altAzimuth(lstDeg, raDeg, decDeg, latitudeDeg);
    // 顶心高度：视差抬高（p 为地平视差，度）。
    final topoAlt = geoAltAz.$1 + hpDeg * _cosDeg(geoAltAz.$1);
    final az = geoAltAz.$2;
    // 地平坐标 → 赤道坐标（azimuth 自北向东为正）。
    final sinDec = _sinDeg(latitudeDeg) * _sinDeg(topoAlt) +
        _cosDeg(latitudeDeg) * _cosDeg(topoAlt) * _cosDeg(az);
    final topoDec = _asinDeg(sinDec);
    final cosH = (_cosDeg(latitudeDeg) * _sinDeg(topoAlt) -
        _sinDeg(latitudeDeg) * _cosDeg(topoAlt) * _cosDeg(az)) /
        _cosDeg(topoDec);
    final sinH = _cosDeg(topoAlt) * _sinDeg(az) / _cosDeg(topoDec);
    final h = _atan2Deg(sinH, cosH);
    final topoRa = _normDeg(lstDeg - h);
    return (topoRa, topoDec);
  }

  // ---------- 相位角 / 亮缘位置角 ----------

  /// cos(相位角)：日月站心夹角（从地球看）。
  static double _cosPhaseAngle(double raS, double decS, double raM,
      double decM) {
    return _sinDeg(decS) * _sinDeg(decM) +
        _cosDeg(decS) * _cosDeg(decM) * _cosDeg(raS - raM);
  }

  /// 亮缘位置角 PA（相对天北点，向东为正，度）。
  static double _positionAngle(double raS, double decS, double raM,
      double decM) {
    return _atan2Deg(
        _cosDeg(decS) * _sinDeg(raS - raM),
        _sinDeg(decS) * _cosDeg(decM) -
            _cosDeg(decS) * _sinDeg(decM) * _cosDeg(raS - raM));
  }

  // ---------- 地平坐标 / 地平纬角 ----------

  /// 月球高度/方位角（度）。方位自北向东为正。
  static (double, double) _altAzimuth(double lstDeg, double raDeg,
      double decDeg, double latitudeDeg) {
    final h = _normDeg(lstDeg - raDeg);
    final sinAlt = _sinDeg(latitudeDeg) * _sinDeg(decDeg) +
        _cosDeg(latitudeDeg) * _cosDeg(decDeg) * _cosDeg(h);
    final alt = _asinDeg(sinAlt);
    final cosAz = (_sinDeg(decDeg) -
        _sinDeg(latitudeDeg) * sinAlt) /
        (_cosDeg(latitudeDeg) * _cosDeg(alt));
    final sinAz = _sinDeg(h) * _cosDeg(decDeg) / _cosDeg(alt);
    final az = _atan2Deg(sinAz, cosAz);
    return (alt, _normDeg(az));
  }

  /// 地平纬角 q：月球处「天顶方向」与「天北方向」的夹角（度）。
  /// 由球面三角形 Z(天顶)-P(天极)-M(月球) 的余弦/正弦定理导出。
  static double _parallacticAngle(double altDeg, double azDeg, double decDeg,
      double latitudeDeg) {
    // sin q = sin(A)·cos(φ)/cos(δ)
    // cos q = (sin φ − sin(alt)·sin(δ)) / (cos(alt)·cos(δ))
    final sinQ = _sinDeg(azDeg) * _cosDeg(latitudeDeg) / _cosDeg(decDeg);
    final cosQ = (_sinDeg(latitudeDeg) -
        _sinDeg(altDeg) * _sinDeg(decDeg)) /
        (_cosDeg(altDeg) * _cosDeg(decDeg));
    return _atan2Deg(sinQ, cosQ);
  }

  // ---------- 八相名称 ----------

  static String _phaseName(double phase01) {
    final p = phase01;
    if (p < 0.03 || p > 0.97) return '朔·新月';
    if (p < 0.25) return '娥眉月';
    if (p < 0.30) return '上弦月';
    if (p < 0.48) return '盈凸月';
    if (p < 0.52) return '望·满月';
    if (p < 0.70) return '亏凸月';
    if (p < 0.78) return '下弦月';
    return '残月';
  }

  // ---------- 工具 ----------

  static double _normDeg(double v) {
    final r = v % 360.0;
    return r < 0 ? r + 360.0 : r;
  }

  static double _sinDeg(double deg) => math.sin(deg * math.pi / 180.0);
  static double _cosDeg(double deg) => math.cos(deg * math.pi / 180.0);
  static double _tanDeg(double deg) => math.tan(deg * math.pi / 180.0);
  static double _atan2Deg(double y, double x) =>
      math.atan2(y, x) * 180.0 / math.pi;
  static double _asinDeg(double v) =>
      math.asin(v.clamp(-1.0, 1.0)) * 180.0 / math.pi;
}
