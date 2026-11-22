// SPDX-License-Identifier: AGPL-3.0-only
// webOS'a özgü işler. Tizen karşılığı: tv-tizen/platform.js
(function () {
  'use strict';

  var NETWORK_STATUS = ['luna://com.webos.service.connectionmanager/getStatus', 'luna://com.palm.connectionmanager/getStatus'];

  // connectionmanager/getStatus yanıtındaki adres: bağlı kablolu, sonra bağlı kablosuz, sonra herhangi biri; yoksa null.
  function addressFromStatus(msg) {
    var status;
    try { status = JSON.parse(msg) || {}; } catch (e) { return null; }
    var wired = status.wired || {};
    var wifi = status.wifi || {};
    if (wired.state === 'connected' && wired.ipAddress) return wired.ipAddress;
    if (wifi.state === 'connected' && wifi.ipAddress) return wifi.ipAddress;
    return wired.ipAddress || wifi.ipAddress || null;
  }

  window.COUCHSUBS_PLATFORM = {
    backKey: 461,

    // HDMI görüntüsü gelmezse app.js nedenini ve giriş seçimini gösterir (Android TV bunu kendi ekranında yapar).
    noPictureHelp: true,

    // Görüntü 'playing' olayı gelmeden de gelmiş olabilir: <video> kare aldıysa görüntü var sayılır.
    hasPicture: function () {
      var video = document.querySelector('#video-host video');
      return !!video && (video.readyState >= 2 || video.videoWidth > 0);
    },

    // Oyun kumandayla oynanır, TV kumandasına dokunulmaz; TV bunu boşta sanıp ekran koruyucuya ve sonra uykuya
    // geçer. TV ekran koruyucuyu açmadan önce abonelere zaman damgalı bir istek yollar; ack:false yanıtı onu erteler
    // (Kodi'nin webOS sürümünün yaptığı gibi). Servis yoksa ya da izin verilmezse sessizce geçilir. Bu istek belgeli
    // değildir ve yeni webOS'ta (25) saat ekran koruyucusu yine geliyordu (#230); appinfo.json'daki belgeli
    // screenSaverProperties.preferredType 2 (OLED, webOS 5+) görüntü üstünde yazı gösteren uygulamalar içindir: tam
    // ekran görüntüde ekran koruyucu açılmaz, yalnız yazı alanı 30 dakikada yavaşça kısılır.
    init: function () {
      var CLIENT = 'com.couchsubs.tv';
      try {
        if (window.PalmSystem) window.PalmSystem.keepAlive = true;
        if (window.webOSSystem) window.webOSSystem.keepAlive = true;
      } catch (e) {}

      function registerSaver() {
        try {
          var register = new PalmServiceBridge();
          register.onservicecallback = function (message) {
            var request;
            try { request = JSON.parse(message); } catch (e) { return; }
            if (!request) return;
            // Panelin tanı satırı için: servis izin vermediyse sebebi, verdiyse ertelenen istek sayısı.
            if (request.returnValue === false) window.__screenSaverStatus = 'denied: ' + (request.errorText || request.errorCode);
            if (request.timestamp === undefined) return;
            window.__screenSaverCount = (window.__screenSaverCount || 0) + 1;
            window.__screenSaverStatus = 'deferred ' + window.__screenSaverCount;
            var reply = new PalmServiceBridge();
            reply.call('luna://com.webos.service.tvpower/power/responseScreenSaverRequest',
              JSON.stringify({ clientName: CLIENT, ack: false, timestamp: request.timestamp }));
            window.__screenSaverReply = reply;
          };
          register.call('luna://com.webos.service.tvpower/power/registerScreenSaverRequest',
            JSON.stringify({ subscribe: true, clientName: CLIENT }));
          // Köprü nesnesi çöpe gitmesin; abonelik uygulama açık kaldıkça sürer.
          window.__screenSaverBridge = register;
        } catch (e) {}
      }

      // Yeni webOS (23/24/25+) sürümlerinde HDMI üstü katman açıkken kumandaya basılmadığı için TV bazen
      // 2-3 dakikada ekran koruyucuya geçebiliyor. 45 saniyede bir çok katmanlı canlılık sinyali bunu engeller.
      function keepScreenAwake() {
        try {
          if (window.PalmSystem) window.PalmSystem.keepAlive = true;
          if (window.webOSSystem) window.webOSSystem.keepAlive = true;
        } catch (e) {}
        try {
          var wake = new PalmServiceBridge();
          wake.call('luna://com.webos.service.tvpower/power/turnOffScreenSaver', '{}');
          window.__screenSaverWake = wake;
        } catch (e) {}
        try {
          var reset = new PalmServiceBridge();
          reset.call('luna://com.webos.service.tvpower/power/resetScreenSaverTimer', '{}');
          window.__screenSaverReset = reset;
        } catch (e) {}
        try {
          var disp = new PalmServiceBridge();
          disp.call('luna://com.palm.display/control/setProperty', JSON.stringify({ timeout: 0 }));
          window.__displayWake = disp;
        } catch (e) {}
        try {
          var video = document.querySelector('#video-host video');
          if (video && video.paused) video.play();
        } catch (e) {}
      }

      registerSaver();
      keepScreenAwake();
      window.__screenSaverTimer = setInterval(keepScreenAwake, 45000);
    },

    launchParams: function () {
      return window.PalmSystem && window.PalmSystem.launchParams;
    },

    onRelaunch: function (callback) {
      document.addEventListener('webOSRelaunch', function (e) { callback(e.detail); });
    },

    // onStatus: 'loading' | 'ready' | 'playing' | 'inputError' | 'sourceError'
    showHdmi: function (port, host, onStatus) {
      host.innerHTML = '';

      var video = document.createElement('video');
      video.autoplay = true;
      var source = document.createElement('source');
      source.setAttribute('type', 'service/webos-external');
      source.setAttribute('src', 'ext://hdmi:' + port);
      video.appendChild(source);

      onStatus('loading');
      video.addEventListener('loadeddata', function () { onStatus('ready'); });
      video.addEventListener('playing', function () { onStatus('playing'); });
      video.addEventListener('error', function () { onStatus('inputError'); });
      source.addEventListener('error', function () { onStatus('sourceError'); });

      host.appendChild(video);
    },

    // TV'nin giriş listesinden oyun konsolunun bağlı olduğu HDMI portunu bulur.
    // Bulamazsa callback'i null ile çağırır.
    findConsolePort: function (callback) {
      var done = false;
      function finish(port, label) {
        if (done) return;
        done = true;
        callback(port, label);
      }
      try {
        var bridge = new PalmServiceBridge();
        bridge.onservicecallback = function (msg) {
          var devices;
          try { devices = JSON.parse(msg).devices || []; } catch (e) { return finish(null); }
          var hdmi = devices.filter(function (d) { return /^HDMI_/.test(d.id); });
          // Konsol dinlenme modundayken giriş etkin görünmez ama etiketi kalır; etkin olan tercih edilir.
          var consoles = hdmi.filter(function (d) {
            return d.spdSourceDeviceInfo === 'GAME' || /playstation|ps5/i.test((d.label || '') + ' ' + (d.spdProductDescription || ''));
          });
          var pick = consoles.filter(function (d) { return d.activate; })[0] || consoles[0] ||
            hdmi.filter(function (d) { return d.activate; })[0];
          finish(pick ? pick.port : null, pick ? pick.label : null);
        };
        bridge.call('luna://com.webos.service.eim/getAllInputStatus', '{}');
        // Köprü nesnesi çöpe gitmesin diye geri çağrı gelene kadar tutulur.
        window.__eimBridge = bridge;
        setTimeout(function () { finish(null); }, 3000);
      } catch (e) {
        finish(null);
      }
    },

    // TV'nin yerel ağdaki IPv4 adresi (kablolu öncelikli); bilinemezse null. Uygulama altyazı kaynağını bu ağda arar.
    // Önce yeni webOS'un hizmeti, yanıt vermezse ya da adres yoksa eski webOS'larınki (com.palm.connectionmanager, LG'nin
    // belgelediği ad) sorulur. Eskiden yalnız ilki soruluyordu; eski LG'lerde adres hiç bilinmiyordu (#469).
    localAddress: function (callback) {
      var done = false;
      function finish(ip) {
        if (done) return;
        done = true;
        callback(ip || null);
      }
      function ask(services, index) {
        if (done) return;
        if (index >= services.length) return finish(null);
        var answered = false;
        function next() {
          if (answered) return;
          answered = true;
          ask(services, index + 1);
        }
        try {
          var bridge = new PalmServiceBridge();
          bridge.onservicecallback = function (msg) {
            if (answered) return;
            var ip = addressFromStatus(msg);
            if (ip) {
              answered = true;
              return finish(ip);
            }
            next();
          };
          bridge.call(services[index], '{}');
          // Köprü nesnesi çöpe gitmesin diye geri çağrı gelene kadar tutulur.
          window['__netBridge' + index] = bridge;
          // İki hizmet birlikte app.js'in 3 sn beklemesine sığar.
          setTimeout(next, 1200);
        } catch (e) {
          next();
        }
      }
      ask(NETWORK_STATUS, 0);
    },

    exit: function () {
      if (window.PalmSystem && window.PalmSystem.platformBack) window.PalmSystem.platformBack();
    }
  };
})();
