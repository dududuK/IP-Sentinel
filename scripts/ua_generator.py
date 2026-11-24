import random
import os

# ==========================================================
# IP-Sentinel 终极动态指纹工厂 (V6.0.0 - 当代版本换代版)
# 战术核心:
# 1. UA 版本必须贴合真实用户分布——陈旧浏览器本身就是 bot 特征
# 2. 平台配比对齐真实市场份额（Chrome/Safari 双寡头，Firefox 长尾）
# 3. 版本号冻结规则遵循浏览器真实行为（Chrome/Edg 尾缀 .0.0.0）
# ==========================================================

TOTAL_POOL = 4000

def weighted_choice(weighted_items):
    items = []
    for value, weight in weighted_items:
        items.extend([value] * weight)
    return random.choice(items)

# ----------------------------------------------------------
# 当代版本池 (2026-11 基准)
# Chrome 稳定通道 ~142-144，Firefox ~145-148，Safari 26.x
# ----------------------------------------------------------
CHROME_MAJORS = [
    ("140", 15),
    ("141", 25),
    ("142", 35),
    ("143", 25),
]

EDGE_MAJORS = [
    ("141", 30),
    ("142", 45),
    ("143", 25),
]

FIREFOX_VERSIONS = [
    ("144", 20),
    ("145", 30),
    ("146", 30),
    ("147", 20),
]

SAFARI_VERSIONS = [
    ("26.0", 55),
    ("26.1", 45),
]

ANDROID_VERSIONS = [
    ("14", 15),
    ("15", 55),
    ("16", 30),
]

# 真实在售主流安卓机型池
ANDROID_MODELS = [
    "Pixel 9", "Pixel 9 Pro", "Pixel 10", "Pixel 10 Pro",
    "SM-S921B", "SM-S926B", "SM-A556B", "SM-A346B",
    "moto g85 5G", "moto g power 5G", "2312DRA50G", "V2329",
    "CPH2651", "CPH2581", "2201117TG", "23127PN0CG",
]


def chrome_major():
    return weighted_choice(CHROME_MAJORS)


def edge_major():
    return weighted_choice(EDGE_MAJORS)


def firefox_ver():
    return weighted_choice(FIREFOX_VERSIONS)


def safari_ver():
    return weighted_choice(SAFARI_VERSIONS)


def android_ver():
    return weighted_choice(ANDROID_VERSIONS)


# ----------------------------------------------------------
# 1. Windows Chrome 桌面 (28% -> 1120条)
# ----------------------------------------------------------
def generate_win_chrome(count=1120):
    uas = []
    for _ in range(count):
        maj = chrome_major()
        # 桌面端 UA 尾缀冻结为 .0.0.0，真实浏览器行为
        uas.append(
            f"Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            f"AppleWebKit/537.36 (KHTML, like Gecko) "
            f"Chrome/{maj}.0.0.0 Safari/537.36"
        )
    return uas


# ----------------------------------------------------------
# 2. Windows Edge 桌面 (7% -> 280条)
# ----------------------------------------------------------
def generate_win_edge(count=280):
    uas = []
    for _ in range(count):
        cmaj = chrome_major()
        emaj = edge_major()
        uas.append(
            f"Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            f"AppleWebKit/537.36 (KHTML, like Gecko) "
            f"Chrome/{cmaj}.0.0.0 Safari/537.36 Edg/{emaj}.0.0.0"
        )
    return uas


# ----------------------------------------------------------
# 3. macOS Chrome 桌面 (6% -> 240条)
# ----------------------------------------------------------
def generate_mac_chrome(count=240):
    uas = []
    for _ in range(count):
        maj = chrome_major()
        uas.append(
            f"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            f"AppleWebKit/537.36 (KHTML, like Gecko) "
            f"Chrome/{maj}.0.0.0 Safari/537.36"
        )
    return uas


# ----------------------------------------------------------
# 4. macOS Safari 桌面 (9% -> 360条)
# ----------------------------------------------------------
def generate_mac_safari(count=360):
    uas = []
    for _ in range(count):
        ver = safari_ver()
        major = ver.split(".")[0]
        # Safari 26 起 Apple 改用年份版本号，WebKit 仍冻结 605.1.15
        uas.append(
            f"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            f"AppleWebKit/605.1.15 (KHTML, like Gecko) "
            f"Version/{ver} Safari/605.1.15"
        )
    return uas


# ----------------------------------------------------------
# 5. iOS Safari (iPhone/iPad) (17% -> 680条)
# ----------------------------------------------------------
def generate_ios_safari(count=680):
    uas = []
    for _ in range(count):
        device = random.choices(["iphone", "ipad"], weights=[88, 12])[0]
        ver = safari_ver()
        ios_ver = random.choices(["18", "26"], weights=[20, 80])[0]
        minor = random.randint(0, 5)
        if device == "iphone":
            # iOS 17+ Safari UA 冻结设备标识，仅暴露 "iPhone" 令牌
            uas.append(
                f"Mozilla/5.0 (iPhone; CPU iPhone OS {ios_ver}_{minor} like Mac OS X) "
                f"AppleWebKit/605.1.15 (KHTML, like Gecko) "
                f"Version/{ver} Mobile/15E148 Safari/604.1"
            )
        else:
            uas.append(
                f"Mozilla/5.0 (iPad; CPU OS {ios_ver}_{minor} like Mac OS X) "
                f"AppleWebKit/605.1.15 (KHTML, like Gecko) "
                f"Version/{ver} Mobile/15E148 Safari/604.1"
            )
    return uas


# ----------------------------------------------------------
# 6. Android Chrome 移动 (21% -> 840条)
# ----------------------------------------------------------
def generate_android_chrome(count=840):
    uas = []
    for _ in range(count):
        maj = chrome_major()
        aver = android_ver()
        model = random.choice(ANDROID_MODELS)
        uas.append(
            f"Mozilla/5.0 (Linux; Android {aver}; {model}) "
            f"AppleWebKit/537.36 (KHTML, like Gecko) "
            f"Chrome/{maj}.0.0.0 Mobile Safari/537.36"
        )
    return uas


# ----------------------------------------------------------
# 7. Android Samsung Internet (4% -> 160条)
# ----------------------------------------------------------
def generate_samsung_internet(count=160):
    uas = []
    samsung_models = ["SM-S921B", "SM-S926B", "SM-A556B", "SM-A346B", "SM-F946B"]
    for _ in range(count):
        cmaj = chrome_major()
        aver = android_ver()
        model = random.choice(samsung_models)
        # Samsung Internet 版本与 Chrome 内核大版本对齐
        smaj = str(int(cmaj) - random.randint(2, 6))
        uas.append(
            f"Mozilla/5.0 (Linux; Android {aver}; {model}) "
            f"AppleWebKit/537.36 (KHTML, like Gecko) "
            f"SamsungBrowser/{smaj}.0 Chrome/{cmaj}.0.0.0 Mobile Safari/537.36"
        )
    return uas


# ----------------------------------------------------------
# 8. Linux Firefox 桌面 (3% -> 120条)
# ----------------------------------------------------------
def generate_linux_firefox(count=120):
    uas = []
    distros = [
        "X11; Linux x86_64",
        "X11; Ubuntu; Linux x86_64",
        "X11; Fedora; Linux x86_64",
        "X11; Debian; Linux x86_64",
    ]
    for _ in range(count):
        ver = firefox_ver()
        distro = random.choice(distros)
        uas.append(
            f"Mozilla/5.0 ({distro}; rv:{ver}.0) Gecko/20100101 Firefox/{ver}.0"
        )
    return uas


# ----------------------------------------------------------
# 9. Linux Chrome 桌面 (2% -> 80条)
# ----------------------------------------------------------
def generate_linux_chrome(count=80):
    uas = []
    for _ in range(count):
        maj = chrome_major()
        distro = random.choice(["X11; Linux x86_64", "X11; Ubuntu; Linux x86_64"])
        uas.append(
            f"Mozilla/5.0 ({distro}) AppleWebKit/537.36 "
            f"(KHTML, like Gecko) Chrome/{maj}.0.0.0 Safari/537.36"
        )
    return uas


# ----------------------------------------------------------
# 10. Windows Firefox 桌面 (2% -> 80条)
# ----------------------------------------------------------
def generate_win_firefox(count=80):
    uas = []
    for _ in range(count):
        ver = firefox_ver()
        uas.append(
            f"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:{ver}.0) "
            f"Gecko/20100101 Firefox/{ver}.0"
        )
    return uas


# ----------------------------------------------------------
# 11. Android Firefox (1% -> 40条)
# ----------------------------------------------------------
def generate_android_firefox(count=40):
    uas = []
    for _ in range(count):
        ver = firefox_ver()
        aver = android_ver()
        model = random.choice(ANDROID_MODELS)
        uas.append(
            f"Mozilla/5.0 (Android {aver}; Mobile; rv:{ver}.0) "
            f"Gecko/{ver}.0 Firefox/{ver}.0"
        )
    return uas


# ----------------------------------------------------------
# 主程序
# ----------------------------------------------------------
if __name__ == "__main__":
    os.makedirs("data", exist_ok=True)
    pool = []

    pool.extend(generate_win_chrome(1120))          # 28%
    pool.extend(generate_ios_safari(680))           # 17%
    pool.extend(generate_android_chrome(840))       # 21%
    pool.extend(generate_mac_safari(360))           # 9%
    pool.extend(generate_win_edge(280))             # 7%
    pool.extend(generate_mac_chrome(240))           # 6%
    pool.extend(generate_samsung_internet(160))     # 4%
    pool.extend(generate_linux_firefox(120))        # 3%
    pool.extend(generate_linux_chrome(80))          # 2%
    pool.extend(generate_win_firefox(80))           # 2%
    pool.extend(generate_android_firefox(40))       # 1%

    random.shuffle(pool)

    final_pool = pool[:TOTAL_POOL]

    output_file = "data/user_agents.txt"
    with open(output_file, "w", encoding="utf-8") as f:
        for ua in final_pool:
            f.write(ua + "\n")

    print(f"✅ 成功生成 {len(final_pool)} 条当代指纹库 (V6.0.0 版本换代版)")
