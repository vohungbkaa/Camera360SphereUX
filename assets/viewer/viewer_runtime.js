(function () {
  'use strict';

  let viewer = null;
  let gyroscope = null;
  let lastPositionMessageAt = 0;
  let viewBounds = null;
  let isClamping = false;
  let initialPose = { yaw: 0, pitch: 0 };

  function radians(degrees) {
    return Number(degrees || 0) * Math.PI / 180;
  }

  function signedYaw(value) {
    return ((value + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI;
  }

  function post(type, payload) {
    const channel = window.Camera360Bridge;
    if (!channel || typeof channel.postMessage !== 'function') return;
    channel.postMessage(JSON.stringify({ type, payload: payload || {} }));
  }

  function reportError(error) {
    post('error', {
      code: 'viewerError',
      message: error && error.message ? error.message : 'Không thể hiển thị ảnh 360°.',
    });
  }

  async function initialize(config) {
    try {
      const psv = window.Camera360PSV;
      if (!psv || !psv.Viewer) throw new Error('Photo Sphere Viewer chưa được tải.');

      const hasYawBounds = Number.isFinite(config.minimumYawDegrees)
        && Number.isFinite(config.maximumYawDegrees);
      const hasPitchBounds = Number.isFinite(config.minimumPitchDegrees)
        && Number.isFinite(config.maximumPitchDegrees);
      const panoData = config.panoData || null;
      const pixelsPerDegree = panoData
        ? Number(panoData.fullWidth || 0) / 360
        : 0;
      const viewportWidth = Math.max(window.innerWidth || 0, 1);
      const resolutionLimitedFov = pixelsPerDegree > 0
        ? viewportWidth / pixelsPerDegree * 0.85
        : 30;
      const minimumFov = Math.max(30, Math.min(65, resolutionLimitedFov));
      initialPose = {
        yaw: radians(config.initialYawDegrees),
        pitch: radians(config.initialPitchDegrees),
      };
      viewBounds = (hasYawBounds || hasPitchBounds) ? {
        minYaw: hasYawBounds ? radians(config.minimumYawDegrees) : null,
        maxYaw: hasYawBounds ? radians(config.maximumYawDegrees) : null,
        minPitch: hasPitchBounds ? radians(config.minimumPitchDegrees) : null,
        maxPitch: hasPitchBounds ? radians(config.maximumPitchDegrees) : null,
      } : null;
      viewer = new psv.Viewer({
        container: document.getElementById('viewer'),
        panorama: config.panorama,
        panoData: panoData,
        minFov: minimumFov,
        maxFov: 100,
        defaultZoomLvl: 45,
        defaultYaw: radians(config.initialYawDegrees),
        defaultPitch: radians(config.initialPitchDegrees),
        mousemove: true,
        mousewheel: true,
        moveSpeed: 1.8,
        moveInertia: 0.55,
        touchmoveTwoFingers: false,
        navbar: ['zoom', 'caption', 'fullscreen'],
        caption: 'Camera 360',
        loadingTxt: 'Đang mở không gian…',
        lang: {
          zoom: 'Thu phóng',
          zoomOut: 'Thu nhỏ',
          zoomIn: 'Phóng to',
          moveUp: 'Nhìn lên',
          moveDown: 'Nhìn xuống',
          moveLeft: 'Nhìn trái',
          moveRight: 'Nhìn phải',
          description: 'Thông tin',
          download: 'Tải xuống',
          fullscreen: 'Toàn màn hình',
          loading: 'Đang tải…',
          menu: 'Menu',
          close: 'Đóng',
          twoFingers: 'Dùng hai ngón tay để điều khiển',
          ctrlZoom: 'Giữ Ctrl để thu phóng',
          loadError: 'Không thể mở ảnh toàn cảnh',
          webglError: 'Thiết bị không hỗ trợ WebGL',
          gyroscope: 'Cảm biến chuyển động',
        },
        plugins: [[psv.GyroscopePlugin, { moveMode: 'smooth', roll: true }]],
      });

      gyroscope = viewer.getPlugin(psv.GyroscopePlugin);
      viewer.addEventListener(psv.events.ReadyEvent.type, async function () {
        post('ready', { version: psv.VERSION });
        let supported = false;
        try {
          supported = await gyroscope.isSupported();
        } catch (_) {
          supported = false;
        }
        post('capabilities', { gyroscopeAvailable: supported });
      });
      viewer.addEventListener(psv.events.PositionUpdatedEvent.type, function (event) {
        if (viewBounds && !isClamping) {
          const yaw = signedYaw(event.position.yaw);
          const clampedYaw = viewBounds.minYaw === null ? yaw
            : Math.max(viewBounds.minYaw, Math.min(viewBounds.maxYaw, yaw));
          const clampedPitch = viewBounds.minPitch === null ? event.position.pitch
            : Math.max(viewBounds.minPitch, Math.min(viewBounds.maxPitch, event.position.pitch));
          if (Math.abs(clampedYaw - yaw) > 0.001
              || Math.abs(clampedPitch - event.position.pitch) > 0.001) {
            isClamping = true;
            viewer.rotate({ yaw: clampedYaw, pitch: clampedPitch });
            requestAnimationFrame(function () { isClamping = false; });
          }
        }
        const now = Date.now();
        if (now - lastPositionMessageAt < 100) return;
        lastPositionMessageAt = now;
        post('position', {
          yaw: event.position.yaw,
          pitch: event.position.pitch,
        });
      });
    } catch (error) {
      reportError(error);
    }
  }

  function requireViewer() {
    if (!viewer) throw new Error('Viewer chưa sẵn sàng.');
    return viewer;
  }

  window.Camera360Viewer = {
    initialize,
    recenter: function () {
      try {
        requireViewer().rotate(initialPose);
        post('recentered');
      } catch (error) {
        reportError(error);
      }
    },
    setPose: function (yawDegrees, pitchDegrees) {
      try {
        requireViewer().rotate({
          yaw: Number(yawDegrees) * Math.PI / 180,
          pitch: Number(pitchDegrees) * Math.PI / 180,
        });
      } catch (error) {
        reportError(error);
      }
    },
    setGyroscopeEnabled: async function (enabled) {
      try {
        if (!gyroscope) throw new Error('Cảm biến chuyển động chưa sẵn sàng.');
        if (enabled) {
          if (!(await gyroscope.isSupported())) {
            post('gyroscope', { enabled: false, available: false });
            return false;
          }
          await gyroscope.start('smooth');
        } else {
          gyroscope.stop();
        }
        post('gyroscope', { enabled: gyroscope.isEnabled(), available: true });
        return gyroscope.isEnabled();
      } catch (error) {
        post('gyroscope', { enabled: false, available: false });
        reportError(error);
        return false;
      }
    },
    destroy: function () {
      if (viewer) viewer.destroy();
      viewer = null;
      gyroscope = null;
    },
  };

  window.addEventListener('error', function (event) {
    reportError(event.error || new Error(event.message));
  });
  window.addEventListener('unhandledrejection', function (event) {
    reportError(event.reason);
  });
})();
