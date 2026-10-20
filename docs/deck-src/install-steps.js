// Step slides (1-9) of the RPM install deck: a compact diagram on top, the work items below.
// Wording rule: describe WHAT is done and to which standard - never a tool or script that does it.
module.exports = function makeSteps(ctx) {
  const { pptx, C, W, M, badge, txt, under, arrow, panel, stepSlide, icon } = ctx;

  // work items: 2 rows x 3 columns of [icon, what, standard]
  async function worklist(s, items) {
    const top = 4.2, gap = 0.3, cw = (W - 2 * M - gap * 2) / 3, ch = 0.98;
    txt(s, "要做的事", { x: M, y: top, w: 4, h: 0.35, fontSize: 14, bold: true, color: C.mute });
    for (let i = 0; i < items.length; i++) {
      const [ic, what, std] = items[i], x = M + (i % 3) * (cw + gap), y = top + 0.42 + Math.floor(i / 3) * (ch + 0.14);
      panel(s, x, y, cw, ch, C.soft);
      await badge(s, x + 0.45, y + ch / 2, 0.56, ic, C.teal);
      txt(s, what, { x: x + 0.9, y: y + 0.12, w: cw - 1.0, h: 0.38, fontSize: 15, bold: true });
      txt(s, std, { x: x + 0.9, y: y + 0.52, w: cw - 1.0, h: 0.36, fontSize: 14, color: C.body });
    }
  }

  return async function steps() {
    // ---------------------------------------------------------------- 1 download
    {
      const s = stepSlide(0, "只帶 Confluent 原廠套件，OS 與 Java 由行內提供",
        "第一步在可以連外的下載機進行。只下載版本清單上指定的 Confluent 原廠套件（含 Control Center），連同原廠的簽章公鑰一起保存。下載環境用和正式主機同版的精簡系統，算出來的相依才會正確。作業系統需要的套件和 Java 都不帶進去：Java 用 RHEL 自帶的 OpenJDK 21，和其他 OS 套件一樣只列出名稱，交給行內 OS 團隊從既有來源提供，修補也跟著行內的 OS 修補流程。每個檔案都記下來源、版本、雜湊值與下載時間；舊版本也保留，回滾或原廠下架時才有得用。");
      await badge(s, 1.35, 2.85, 1.0, "LuGlobe", C.teal);
      under(s, 1.35, 3.42, 2.0, "外網下載機", null, { headSize: 15 });
      arrow(s, 1.9, 2.85, 2.95, 2.85, C.mute, 2);
      const cards = [
        ["LuPackage", "Confluent 套件", "原廠簽章", C.accent, C.accentSoft, false],
        ["LuMonitor", "Control Center", "原廠簽章", C.accent, C.accentSoft, false],
        ["LuListChecks", "OS 與 Java 清單", "只列名稱，交給行內", C.teal, C.white, true],
      ];
      for (let i = 0; i < cards.length; i++) {
        const [ic, h, b, col, fill, dashed] = cards[i], x = 3.05 + i * 3.25, y = 2.3;
        s.addShape(pptx.ShapeType.roundRect, { x, y, w: 3.0, h: 1.1, rectRadius: 0.12, fill: { color: fill }, line: { color: dashed ? C.teal : fill, width: 1.5, dashType: dashed ? "dash" : "solid" } });
        await badge(s, x + 0.5, y + 0.55, 0.62, ic, col);
        txt(s, h, { x: x + 0.95, y: y + 0.17, w: 2.0, h: 0.4, fontSize: 16, bold: true });
        txt(s, b, { x: x + 0.95, y: y + 0.6, w: 2.0, h: 0.36, fontSize: 14, color: C.body });
      }
      await worklist(s, [
        ["LuListOrdered", "依版本清單下載", "只取指定的精確版本"],
        ["LuBoxes", "精簡的下載環境", "與正式主機同版系統"],
        ["LuKeyRound", "保存原廠公鑰", "之後每一關都用它驗簽"],
        ["LuFingerprint", "記錄每個檔案", "來源、版本、雜湊、時間"],
        ["LuArchive", "保留舊版本", "回滾、原廠下架時仍可用"],
        ["LuFileText", "OS 與 Java 清單", "RHEL 自帶 OpenJDK 21"],
      ]);
    }

    // ---------------------------------------------------------------- 2 verify
    {
      const s = stepSlide(1, "三道檢查全部通過才放行",
        "每個檔案都要通過三道檢查：比對雜湊值確認內容沒有被改過、驗證原廠簽章確認來源、再上傳行內的檔案惡意程式掃描檢測平台取得 OK 報告。驗證報告、掃描 OK 報告與檔案雜湊清單一起隨單附上，依行內引進流程簽核後才放行。任何一個檔案不符就整批退回，不做部分放行。");
      const cy = 2.8;
      await badge(s, 1.25, cy, 0.95, "LuPackage", C.mute);
      under(s, 1.25, cy + 0.55, 1.9, "下載的套件", null, { headSize: 15 });
      const checks = [["LuFingerprint", "指紋"], ["LuShieldCheck", "簽章"], ["LuScanSearch", "掃描"]];
      for (let i = 0; i < 3; i++) {
        const cx = 3.35 + i * 2.05;
        arrow(s, cx - 1.5, cy, cx - 0.55, cy);
        await badge(s, cx, cy, 0.95, checks[i][0], C.teal);
        under(s, cx, cy + 0.55, 1.6, checks[i][1], null, { headSize: 15 });
      }
      s.addShape(pptx.ShapeType.diamond, { x: 8.75, y: cy - 0.65, w: 1.3, h: 1.3, fill: { color: C.accentSoft }, line: { color: C.accent, width: 1.5 } });
      txt(s, "全部\n通過？", { x: 8.75, y: cy - 0.65, w: 1.3, h: 1.3, fontSize: 14, bold: true, align: "center", valign: "middle", color: C.accent });
      arrow(s, 7.95, cy, 8.75, cy);
      arrow(s, 10.05, cy - 0.1, 10.75, cy - 0.5, C.ok);
      arrow(s, 10.05, cy + 0.1, 10.75, cy + 0.5, C.bad);
      await badge(s, 11.1, cy - 0.55, 0.62, "LuCircleCheck", C.ok);
      txt(s, "放行", { x: 11.5, y: cy - 0.75, w: 1.0, h: 0.4, fontSize: 16, bold: true, valign: "middle", color: C.ok });
      await badge(s, 11.1, cy + 0.55, 0.62, "LuCircleX", C.bad);
      txt(s, "整批退回", { x: 11.5, y: cy + 0.35, w: 1.3, h: 0.4, fontSize: 16, bold: true, valign: "middle", color: C.bad });
      await worklist(s, [
        ["LuFingerprint", "比對雜湊值", "每個檔案都比，一個不漏"],
        ["LuShieldCheck", "驗證原廠簽章", "確認來源與內容未被改動"],
        ["LuScanSearch", "行內平台掃描", "上傳檔案，取得 OK 報告"],
        ["LuFileText", "報告隨單附上", "驗證、掃描報告與雜湊清單"],
        ["LuUserCheck", "簽核放行", "依行內軟體引進流程"],
        ["LuCircleX", "不符就整批退回", "不做部分放行"],
      ]);
    }

    // ---------------------------------------------------------------- 3 exchange + publish
    {
      const s = stepSlide(2, "只有驗證過的檔案能進內網",
        "放行的檔案經行內既有的檔案交換平台進入內網，必須是掃描過的同一批檔案。上架前在內網再驗一次雜湊與簽章；已經上架的檔案絕不覆蓋，同名但內容不同就拒絕。接著建立套件索引，由行內套件庫提供給各主機：優先沿用既有的 Satellite、Artifactory 或 Nexus，沒有才用 web server。每次引進的檔案清單與驗證報告都留存，供稽核。");
      const zones = [
        [M, 3.6, "外網區", "可連外", "LuLaptop", C.soft, C.mute],
        [M + 3.85, 3.6, "行內檔案交換", "依行內規範", "LuArrowRightLeft", "E6ECF5", "4E6E9E"],
        [M + 7.7, W - 2 * M - 7.7, "內部套件庫", "完全不連外", "LuDatabase", C.tealSoft, C.teal],
      ];
      for (const [x, w, name, sub, ic, fill, col] of zones) {
        panel(s, x, 1.95, w, 2.1, fill);
        txt(s, name, { x: x + 0.3, y: 2.08, w: w - 1.6, h: 0.42, fontSize: 18, bold: true, color: col });
        txt(s, sub, { x: x + 0.3, y: 2.5, w: w - 1.6, h: 0.36, fontSize: 14, color: C.body });
        await badge(s, x + w - 0.95, 3.0, 1.0, ic, col);
      }
      for (let i = 0; i < 2; i++) arrow(s, zones[i][0] + zones[i][1] - 0.4, 3.0, zones[i + 1][0] + 0.1, 3.0, C.ink, 2.5);
      txt(s, "上架前再驗一次", { x: zones[2][0] + 0.3, y: 3.45, w: 2.6, h: 0.36, fontSize: 14, bold: true, color: C.ok });
      await worklist(s, [
        ["LuArrowRightLeft", "經檔案交換平台", "與掃描過的是同一批檔案"],
        ["LuShieldCheck", "上架前再驗一次", "雜湊與簽章重新比對"],
        ["LuLock", "已上架不可覆蓋", "同名不同內容即拒絕"],
        ["LuDatabase", "建立套件索引", "主機才能依名稱安裝"],
        ["LuServer", "由行內套件庫提供", "沿用既有平台或 web server"],
        ["LuArchive", "留存引進紀錄", "清單與報告供稽核"],
      ]);
    }

    // ---------------------------------------------------------------- 4 host baseline
    {
      const s = stepSlide(3, "每台主機都照同一套標準設定",
        "安裝 Kafka 之前，先把每台主機的作業系統調成同一套標準：檔案數、記憶體、網路緩衝等系統參數調到建議值；關閉透明大頁、避免使用 swap；時間與行內 NTP 同步，誤差小於 1 秒；防火牆只開各元件需要的埠；建立不能登入的服務專用帳號；信任行內 CA，日誌限量保留。");
      const roles = [["LuServerCog", "Controller"], ["LuServer", "Broker"], ["LuNetwork", "REST 介面"], ["LuMonitor", "Control Center"], ["LuLaptop", "操作機"]];
      const step = (W - 2 * M) / roles.length;
      panel(s, M, 1.95, W - 2 * M, 2.1, C.accentSoft);
      for (let i = 0; i < roles.length; i++) {
        const cx = M + step * i + step / 2;
        await badge(s, cx, 2.75, 0.85, roles[i][0], C.accent);
        under(s, cx, 3.27, step - 0.1, roles[i][1], null, { headSize: 15 });
      }
      await worklist(s, [
        ["LuSlidersHorizontal", "系統參數", "檔案數、記憶體、網路緩衝"],
        ["LuMemoryStick", "記憶體行為", "關透明大頁，避免 swap"],
        ["LuClock", "時間同步", "與行內 NTP 誤差小於 1 秒"],
        ["LuBrickWall", "防火牆", "只開各元件需要的埠"],
        ["LuUserCog", "服務專用帳號", "不能登入、不能 SSH"],
        ["LuBadgeCheck", "信任與日誌", "信任行內 CA，日誌限量保留"],
      ]);
    }

    // ---------------------------------------------------------------- 5 install packages
    {
      const s = stepSlide(4, "先試算，通過才安裝，裝完鎖定版本",
        "Confluent 套件從內部套件庫安裝，作業系統套件與 Java 從行內的 RHEL 套件來源安裝；連線都用 HTTPS 並驗證伺服器憑證，安裝時逐一驗證簽章。正式安裝前先試算：確認不缺任何套件，也不會順帶升級其他系統套件。依主機上的元件只裝需要的套件和指定版本，裝完鎖定版本，日後例行更新不會誤升級。Control Center 主機不裝其他平台套件，避免衝突。");
      const steps = [["LuDatabase", "內部套件庫", C.teal], ["LuCalculator", "試算", C.accent], ["LuPackage", "安裝", C.teal], ["LuLock", "鎖定版本", C.teal]];
      const sx = 1.9, step = (W - 2 * sx) / 3, cy = 2.75;
      for (let i = 0; i < steps.length; i++) {
        const cx = sx + i * step;
        await badge(s, cx, cy, 1.0, steps[i][0], steps[i][2]);
        under(s, cx, cy + 0.6, 2.4, steps[i][1], null, { headSize: 16 });
        if (i < 3) arrow(s, cx + 0.62, cy, cx + step - 0.62, cy, C.ink, 2.5);
      }
      await worklist(s, [
        ["LuLink", "指向內部套件庫", "HTTPS，驗證伺服器憑證"],
        ["LuKeyRound", "匯入原廠公鑰", "安裝時逐一驗證簽章"],
        ["LuCalculator", "安裝前試算", "不缺套件、不動系統套件"],
        ["LuPackage", "依元件安裝", "只裝需要的套件與版本"],
        ["LuLock", "鎖定版本", "例行更新不會誤升級"],
        ["LuMonitor", "C3 主機獨立", "不裝其他平台套件"],
      ]);
    }

    // ---------------------------------------------------------------- 6 certificates
    {
      const s = stepSlide(5, "憑證由銀行 CA 簽發，匯入前先檢查",
        "平台之間的連線全部加密。我們在行內產生私鑰與申請單，申請單寫清楚用途、主機名稱與效期，只把申請單交給銀行 CA，私鑰不離開行內。簽回後先檢查名稱、用途、效期、憑證鏈，以及和私鑰是否相符，全部正確才部署。伺服器、內部通訊、各平台服務各用各的憑證；應用程式多半直連 Kafka、用帳號密碼，不需要憑證；只有經 REST 介面的應用程式要各發一張憑證，以憑證識別身分；所有主機都信任銀行根憑證；到期前 30 天提出換發。");
      panel(s, M, 1.95, W - 2 * M, 1.0, C.soft);
      panel(s, M, 3.05, W - 2 * M, 1.0, C.accentSoft);
      txt(s, "我方", { x: M + 0.25, y: 1.95, w: 1.2, h: 1.0, fontSize: 16, bold: true, color: C.teal, valign: "middle" });
      txt(s, "銀行 CA", { x: M + 0.25, y: 3.05, w: 1.4, h: 1.0, fontSize: 16, bold: true, color: C.accent, valign: "middle" });
      const pts = [[3.3, 2.45, "LuFileText", "產生申請單", C.teal], [5.9, 3.55, "LuStamp", "簽發", C.accent],
        [8.5, 2.45, "LuSearchCheck", "匯入前檢查", C.teal], [11.1, 2.45, "LuServer", "部署到主機", C.teal]];
      for (let i = 0; i < pts.length; i++) {
        const [cx, cy, ic, h, col] = pts[i];
        await badge(s, cx - 0.65, cy, 0.62, ic, col);
        txt(s, h, { x: cx - 0.25, y: cy - 0.22, w: 1.6, h: 0.44, fontSize: 15, bold: true, valign: "middle" });
        if (i < pts.length - 1) {
          const [nx, ny] = pts[i + 1];
          if (ny === cy) arrow(s, cx + 1.25, cy, nx - 1.05, ny, C.ink);
          else if (ny > cy) arrow(s, cx - 0.3, cy + 0.36, nx - 1.0, ny - 0.1, C.ink);
          else arrow(s, cx + 0.45, cy - 0.15, nx - 1.0, ny + 0.3, C.ink);
        }
      }
      await worklist(s, [
        ["LuFileText", "申請單寫清用途", "用途、主機名稱、效期"],
        ["LuKeyRound", "私鑰不外流", "只交申請單給銀行"],
        ["LuSearchCheck", "匯入前檢查", "名稱、用途、效期、憑證鏈"],
        ["LuLayers", "依用途分開", "伺服器、內部、各服務各一張"],
        ["LuShieldCheck", "全部主機信任", "銀行根憑證放入信任清單"],
        ["LuCalendarClock", "到期前換發", "到期前 30 天提出申請"],
      ]);
    }

    // ---------------------------------------------------------------- 7 configure + start
    {
      const s = stepSlide(6, "依序啟動，健康才進下一段",
        "依主機上的元件產生設定檔，不從範例檔手改；設定裡的密碼加密保存，設定檔與私鑰只有服務帳號讀得到。叢集儲存只初始化一次。啟動有固定順序：先啟動管理叢集的 controller，確認成員到齊；再啟動存放資料的 broker，確認每台都已加入；最後才啟動 REST 介面與 Control Center：REST 由負載平衡器提供給應用程式，Control Center 由維運人員經 VDI 直連。任何一段不健康就停下來處理，不往下一段走。");
      const stages = [
        ["Controller", ["LuServerCog", "LuServerCog", "LuServerCog"], C.accent, C.accentSoft],
        ["Broker", ["LuServer", "LuServer", "LuServer", "LuServer"], C.accent, C.accentSoft],
        ["REST ／ C3", ["LuNetwork", "LuNetwork", "LuMonitor"], C.teal, C.tealSoft],
      ];
      const sw = 3.1, gapW = 1.45, sy = 1.95, sh = 2.1;
      for (let i = 0; i < stages.length; i++) {
        const [name, ics, col, fill] = stages[i], x = M + i * (sw + gapW);
        panel(s, x, sy, sw, sh, fill);
        txt(s, `${i + 1}  ${name}`, { x: x + 0.25, y: sy + 0.18, w: sw - 0.4, h: 0.45, fontSize: 15, bold: true, color: col });
        const d = 0.6, g = 0.12, tw = ics.length * d + (ics.length - 1) * g;
        for (let k = 0; k < ics.length; k++) await badge(s, x + (sw - tw) / 2 + d / 2 + k * (d + g), sy + 1.3, d, ics[k], col);
        if (i < 2) {
          const hx = x + sw + gapW / 2, hy = sy + sh / 2;
          await badge(s, hx, hy - 0.15, 0.7, "LuHeartPulse", C.ok);
          txt(s, "健康檢查", { x: hx - 0.7, y: hy + 0.25, w: 1.4, h: 0.36, fontSize: 14, bold: true, align: "center", color: C.ok });
          arrow(s, x + sw + 0.05, hy - 0.15, hx - 0.4, hy - 0.15, C.ok, 1.75);
          arrow(s, hx + 0.4, hy - 0.15, x + sw + gapW - 0.05, hy - 0.15, C.ok, 1.75);
        }
      }
      await worklist(s, [
        ["LuFileCog", "依元件產生設定", "不從範例檔手改"],
        ["LuLockKeyhole", "密碼加密保存", "只有服務帳號讀得到"],
        ["LuHardDrive", "初始化叢集儲存", "只做一次"],
        ["LuListOrdered", "依序啟動", "controller → broker → 對外"],
        ["LuHeartPulse", "每段確認健康", "成員到齊、服務有回應"],
        ["LuNetwork", "REST 經負載平衡", "C3 由維運人員直連"],
      ]);
    }

    // ---------------------------------------------------------------- 8 access
    {
      const s = stepSlide(7, "人與程式分開認證，權限一律控管",
        "人員用行內 AD 帳號登入，權限依 AD 群組決定（管理、維運、開發）。每個應用程式都有專屬身分，只能存取自己的資料：直連 Kafka 的應用程式用專屬帳號密碼（SCRAM），經 REST 介面的應用程式一律用專屬憑證（應用程式不在 AD 建帳號，所以 REST 介面無法用帳號密碼驗證它們）。平台內部的服務用憑證識別，不在 AD 建帳號、沒有密碼。所有存取都留下稽核紀錄，一般保留 90 天、敏感資料 365 天。每個應用程式有流量配額，單一應用不會拖垮叢集；管理用的身分不能被別人代理使用。");
      await badge(s, 1.35, 2.45, 0.8, "LuUsers", C.teal);
      txt(s, "人員：AD 帳號", { x: 1.9, y: 2.25, w: 2.8, h: 0.4, fontSize: 16, bold: true, valign: "middle" });
      await badge(s, 1.35, 3.55, 0.8, "LuBot", C.teal);
      txt(s, "應用程式：專屬帳號", { x: 1.9, y: 3.35, w: 2.9, h: 0.4, fontSize: 16, bold: true, valign: "middle" });
      const gx = 6.7, gy = 3.0;
      arrow(s, 4.85, 2.45, gx - 0.65, gy - 0.25, C.ink);
      arrow(s, 4.85, 3.55, gx - 0.65, gy + 0.25, C.ink);
      await badge(s, gx, gy, 1.1, "LuShieldCheck", C.accent);
      txt(s, "權限控管", { x: gx + 0.65, y: gy - 0.2, w: 1.5, h: 0.4, fontSize: 16, bold: true, valign: "middle" });
      arrow(s, gx + 2.15, gy, 9.95, gy, C.ink, 2.5);
      await badge(s, 10.55, gy, 1.0, "LuLayers", C.ink);
      txt(s, "Kafka 平台", { x: 11.1, y: gy - 0.2, w: 1.6, h: 0.4, fontSize: 16, bold: true, valign: "middle" });
      await worklist(s, [
        ["LuUsers", "人員依 AD 群組", "管理、維運、開發三種"],
        ["LuBot", "應用程式專屬帳號", "直連用帳密，經 REST 用憑證"],
        ["LuBadgeCheck", "平台服務用憑證", "不在 AD 建帳號、沒有密碼"],
        ["LuScrollText", "稽核紀錄", "一般 90 天、敏感 365 天"],
        ["LuGauge", "流量配額", "單一應用不拖垮叢集"],
        ["LuShield", "管理身分受保護", "不能被他人代理使用"],
      ]);
    }

    // ---------------------------------------------------------------- 9 acceptance
    {
      const s = stepSlide(8, "逐項驗收，全數通過才算完成",
        `安裝的最後一步是驗收，共 ${ctx.VERIFY_TOTAL} 項，涵蓋叢集運作、加密連線、身分與權限、高可用切換、監控與離線隔離。每一項都有明確的通過標準，結果逐項留存；全部通過才算安裝完成。`);
      panel(s, M, 2.15, 3.6, 4.2, C.accentSoft);
      txt(s, ctx.VERIFY_TOTAL, { x: M, y: 2.6, w: 3.6, h: 1.5, fontSize: 80, bold: true, align: "center", valign: "middle", color: C.accent });
      txt(s, "項驗收", { x: M, y: 4.1, w: 3.6, h: 0.5, fontSize: 20, bold: true, align: "center" });
      txt(s, "全數通過", { x: M, y: 4.65, w: 3.6, h: 0.5, fontSize: 20, bold: true, align: "center", color: C.ok });
      txt(s, "每項有通過標準\n結果逐項留存", { x: M + 0.2, y: 5.3, w: 3.2, h: 0.8, fontSize: 14, align: "center", color: C.body });
      const tiles = [
        ["LuActivity", "叢集運作"], ["LuLock", "加密連線"], ["LuIdCard", "身分與權限"],
        ["LuRefreshCw", "高可用切換"], ["LuChartLine", "監控"], ["LuWifiOff", "離線隔離"],
      ];
      const gx = M + 3.9, gw = W - M - gx, tw = (gw - 0.3 * 2) / 3, th = (4.2 - 0.3) / 2;
      for (let i = 0; i < tiles.length; i++) {
        const x = gx + (i % 3) * (tw + 0.3), y = 2.15 + Math.floor(i / 3) * (th + 0.3);
        panel(s, x, y, tw, th, C.soft);
        await badge(s, x + tw / 2, y + 0.75, 0.85, tiles[i][0], C.teal);
        txt(s, tiles[i][1], { x, y: y + 1.3, w: tw, h: 0.45, fontSize: 18, bold: true, align: "center" });
        s.addImage({ data: await icon("LuCircleCheck", C.ok), x: x + tw - 0.55, y: y + 0.2, w: 0.35, h: 0.35 });
      }
    }
  };
};
