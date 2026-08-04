const statusEl = document.querySelector("#status");
const chooser = document.querySelector("#chooser");
const hostPanel = document.querySelector("#hostPanel");
const viewerPanel = document.querySelector("#viewerPanel");
const preview = document.querySelector("#preview");
const remoteVideo = document.querySelector("#remoteVideo");
const viewerCount = document.querySelector("#viewerCount");
const enablePlayback = document.querySelector("#enablePlayback");

const peers = new Map();
let socket;
let selfId;
let localStream;
let role;

const rtcConfig = {
  iceServers: [],
  bundlePolicy: "max-bundle",
  rtcpMuxPolicy: "require"
};

function setStatus(text) {
  statusEl.textContent = text;
}

function connect(selectedRole) {
  role = selectedRole;
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  socket = new WebSocket(`${protocol}//${location.host}/signal`);
  socket.addEventListener("open", () => {
    setStatus("Сигналинг подключён");
    socket.send(JSON.stringify({ type: "register", role }));
  });
  socket.addEventListener("close", () => setStatus("Соединение закрыто"));
  socket.addEventListener("message", handleSignalMessage);
}

async function handleSignalMessage(event) {
  const message = JSON.parse(event.data);
  if (message.type === "welcome") {
    selfId = message.id;
    if (role === "viewer" && !message.hostOnline) setStatus("Ждём передатчик");
    return;
  }
  if (message.type === "error") {
    setStatus(message.message);
    return;
  }
  if (message.type === "host-online" && role === "viewer") {
    setStatus("Передатчик найден");
    return;
  }
  if (message.type === "host-offline" && role === "viewer") {
    remoteVideo.srcObject = null;
    setStatus("Передатчик отключился");
    return;
  }
  if (message.type === "viewer-joined" && role === "host" && localStream) {
    await createOfferForViewer(message.viewerId);
    return;
  }
  if (message.type === "viewer-left" && role === "host") {
    closePeer(message.viewerId);
    updateViewerCount();
    return;
  }
  if (message.type === "signal") {
    await handlePeerSignal(message.from, message.payload);
  }
}

function sendSignal(target, payload) {
  socket.send(JSON.stringify({ type: "signal", target, payload }));
}

function createPeer(peerId) {
  const peer = new RTCPeerConnection(rtcConfig);
  peers.set(peerId, peer);

  peer.onicecandidate = ({ candidate }) => {
    if (candidate) sendSignal(peerId, { candidate });
  };

  peer.onconnectionstatechange = () => {
    setStatus(`WebRTC: ${peer.connectionState}`);
    if (["failed", "closed", "disconnected"].includes(peer.connectionState)) {
      closePeer(peerId);
      updateViewerCount();
    }
  };

  if (role === "viewer") {
    peer.ontrack = async ({ streams }) => {
      remoteVideo.srcObject = streams[0];
      try {
        await remoteVideo.play();
        enablePlayback.classList.add("hidden");
      } catch {
        enablePlayback.classList.remove("hidden");
      }
      setStatus("Трансляция идёт");
    };
  }

  return peer;
}

async function createOfferForViewer(viewerId) {
  const peer = createPeer(viewerId);
  for (const track of localStream.getTracks()) peer.addTrack(track, localStream);

  const offer = await peer.createOffer({ offerToReceiveAudio: false, offerToReceiveVideo: false });
  await peer.setLocalDescription(offer);
  sendSignal(viewerId, { description: peer.localDescription });
  updateViewerCount();
}

async function handlePeerSignal(peerId, payload) {
  let peer = peers.get(peerId);
  if (!peer) peer = createPeer(peerId);

  if (payload.description) {
    await peer.setRemoteDescription(payload.description);
    if (payload.description.type === "offer") {
      const answer = await peer.createAnswer();
      await peer.setLocalDescription(answer);
      sendSignal(peerId, { description: peer.localDescription });
    }
  }

  if (payload.candidate) {
    await peer.addIceCandidate(payload.candidate);
  }
}

function closePeer(peerId) {
  peers.get(peerId)?.close();
  peers.delete(peerId);
}

function updateViewerCount() {
  viewerCount.textContent = `Подключено зрителей: ${peers.size}`;
}

async function startSharing() {
  try {
    localStream = await navigator.mediaDevices.getDisplayMedia({
      video: {
        frameRate: { ideal: 60, max: 60 },
        width: { ideal: 1920 },
        height: { ideal: 1080 }
      },
      audio: {
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
        channelCount: 2,
        sampleRate: 48000
      },
      preferCurrentTab: false,
      selfBrowserSurface: "exclude",
      surfaceSwitching: "include",
      systemAudio: "include"
    });

    preview.srcObject = localStream;
    document.querySelector("#startShare").disabled = true;
    document.querySelector("#stopShare").disabled = false;
    setStatus("Экран захвачен");

    const [videoTrack] = localStream.getVideoTracks();
    if (videoTrack) {
      videoTrack.contentHint = "motion";
      videoTrack.addEventListener("ended", stopSharing);
    }
    for (const audioTrack of localStream.getAudioTracks()) audioTrack.contentHint = "music";
  } catch (error) {
    console.error(error);
    setStatus("Захват отменён или недоступен");
  }
}

function stopSharing() {
  for (const track of localStream?.getTracks() ?? []) track.stop();
  localStream = undefined;
  preview.srcObject = null;
  for (const peerId of peers.keys()) closePeer(peerId);
  document.querySelector("#startShare").disabled = false;
  document.querySelector("#stopShare").disabled = true;
  updateViewerCount();
  setStatus("Трансляция остановлена");
}

document.querySelector("#hostMode").addEventListener("click", () => {
  chooser.classList.add("hidden");
  hostPanel.classList.remove("hidden");
  connect("host");
});

document.querySelector("#viewerMode").addEventListener("click", () => {
  chooser.classList.add("hidden");
  viewerPanel.classList.remove("hidden");
  connect("viewer");
});

document.querySelector("#startShare").addEventListener("click", startSharing);
document.querySelector("#stopShare").addEventListener("click", stopSharing);
enablePlayback.addEventListener("click", async () => {
  await remoteVideo.play();
  enablePlayback.classList.add("hidden");
});
