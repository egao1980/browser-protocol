// A test page for browser-protocol/record: playTone(frequency, seconds,
// delay) plays a sine through Web Audio, DELAY seconds from now on the
// AudioContext's clock, and turns the page white when the tone's first
// sample is heard (getOutputTimestamp). window.tone records the times.
window.playTone = function (frequency, seconds, delay) {
  var ctx = new AudioContext();
  var osc = ctx.createOscillator();
  var gain = ctx.createGain();
  osc.frequency.value = frequency;
  gain.gain.value = 0.5;
  osc.connect(gain);
  gain.connect(ctx.destination);
  var start = ctx.currentTime + delay;
  osc.start(start);
  osc.stop(start + seconds);
  window.tone = { start: start, rate: ctx.sampleRate, state: ctx.state };
  function watch() {
    var ots = ctx.getOutputTimestamp();
    if (ots.performanceTime > 0 && ots.contextTime >= start) {
      document.body.className = 'on';
      window.tone.heardEpoch = performance.timeOrigin + ots.performanceTime
        + (start - ots.contextTime) * 1000;
      window.tone.shownEpoch = performance.timeOrigin + performance.now();
      return;
    }
    requestAnimationFrame(watch);
  }
  requestAnimationFrame(watch);
  return ctx.state;
};
