import React from "react";
import {
  AbsoluteFill,
  Audio,
  Img,
  OffthreadVideo,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { loadFont } from "@remotion/google-fonts/RussoOne";

const { fontFamily } = loadFont("normal", { subsets: ["latin", "cyrillic"], weights: ["400"] });

export type PromoProps = { lang: "en" | "ru"; vertical: boolean };

// Cut points (frames @30fps) - they match the hits in make-audio.mjs.
const CUTS = [0, 84, 169, 281, 408, 548, 731, 900];
const ACCENT = "#9a8cff";
const DARK = "#0b0a24";

const T = {
  en: {
    hook1: "300 EMPIRES.",
    hook2: "ONE MAP.",
    pick: "PICK YOUR START",
    expand: "EXPAND",
    attack: "ATTACK",
    build: "BUILD · ALLY · BETRAY",
    rule1: "ONE EMPIRE",
    rule2: "WILL RULE THE WORLD",
    free: "FREE ON ROBLOX",
    search: "Search “WW3: High Command”",
  },
  ru: {
    hook1: "300 ИМПЕРИЙ.",
    hook2: "ОДНА КАРТА.",
    pick: "ВЫБЕРИ СТАРТ",
    expand: "РАСШИРЯЙСЯ",
    attack: "АТАКУЙ",
    build: "СТРОЙ · ДРУЖИ · ПРЕДАВАЙ",
    rule1: "ОДНА ИМПЕРИЯ",
    rule2: "БУДЕТ ПРАВИТЬ МИРОМ",
    free: "БЕСПЛАТНО В ROBLOX",
    search: "Ищи «WW3: High Command»",
  },
};

// Text that slams in with a spring, with a thick outline.
const Slam: React.FC<{ text: string; delay?: number; size: number; color?: string; style?: React.CSSProperties }> = ({
  text,
  delay = 0,
  size,
  color = "#fff",
  style,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: frame - delay, fps, config: { damping: 11, stiffness: 190, mass: 0.7 } });
  const scale = interpolate(s, [0, 1], [1.9, 1]);
  const opacity = interpolate(frame - delay, [0, 3], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <div
      style={{
        fontFamily,
        fontSize: size,
        lineHeight: 1.02,
        color,
        textAlign: "center",
        letterSpacing: 2,
        transform: `scale(${scale})`,
        opacity,
        WebkitTextStroke: `${Math.round(size / 11)}px ${DARK}`,
        paintOrder: "stroke fill",
        textShadow: `0 ${size / 10}px 0 ${DARK}, 0 0 ${size / 2}px ${ACCENT}aa`,
        ...style,
      }}
    >
      {text}
    </div>
  );
};

// White flash + tiny shake at the start of every shot.
const Hit: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const frame = useCurrentFrame();
  const flash = interpolate(frame, [0, 7], [0.85, 0], { extrapolateRight: "clamp" });
  const k = Math.max(0, 1 - frame / 8);
  const dx = Math.sin(frame * 3.1) * 14 * k;
  const dy = Math.cos(frame * 2.7) * 14 * k;
  return (
    <AbsoluteFill style={{ transform: `translate(${dx}px, ${dy}px)` }}>
      {children}
      <AbsoluteFill style={{ background: "#fff", opacity: flash, mixBlendMode: "screen" }} />
    </AbsoluteFill>
  );
};

const Vignette: React.FC = () => (
  <AbsoluteFill
    style={{ background: "radial-gradient(ellipse at center, rgba(0,0,0,0) 45%, rgba(5,4,25,0.75) 100%)" }}
  />
);

// Gameplay clip: full-bleed on 16:9, framed card over a blurred copy on 9:16.
const Clip: React.FC<{ src: string; from?: number; zoom?: number; vertical: boolean; tall?: boolean; pos?: string }> = ({
  src,
  from = 0,
  zoom = 0.1,
  vertical,
  tall = false,
  pos = "50% 50%",
}) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const scale = 1 + interpolate(frame, [0, durationInFrames], [0, zoom]);
  if (!vertical) {
    return (
      <AbsoluteFill style={{ background: DARK }}>
        <AbsoluteFill style={{ transform: `scale(${scale * 1.12})` }}>
          <OffthreadVideo src={staticFile(src)} startFrom={from} muted style={{ width: "100%", height: "100%", objectFit: "cover" }} />
        </AbsoluteFill>
        <Vignette />
      </AbsoluteFill>
    );
  }
  return (
    <AbsoluteFill style={{ background: DARK }}>
      <AbsoluteFill style={{ filter: "blur(38px) brightness(0.55) saturate(1.3)", transform: "scale(1.25)" }}>
        <OffthreadVideo src={staticFile(src)} startFrom={from} muted style={{ width: "100%", height: "100%", objectFit: "cover" }} />
      </AbsoluteFill>
      <AbsoluteFill style={{ justifyContent: "center", alignItems: "center" }}>
        <div
          style={{
            width: 1040,
            height: tall ? 1180 : 1040 * (792 / 1600) * 1.35,
            overflow: "hidden",
            borderRadius: 26,
            border: `6px solid ${ACCENT}`,
            boxShadow: `0 0 90px ${ACCENT}99, 0 30px 80px #000c`,
            transform: `scale(${scale})`,
          }}
        >
          <OffthreadVideo src={staticFile(src)} startFrom={from} muted style={{ width: "100%", height: "100%", objectFit: "cover", objectPosition: pos }} />
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

const Shot: React.FC<{
  vertical: boolean;
  src: string;
  from?: number;
  zoom?: number;
  top?: string;
  bottom?: string[];
  topSize?: number;
  tall?: boolean;
  pos?: string;
}> = ({ vertical, src, from, zoom, top, bottom, topSize, tall, pos }) => {
  const size = topSize ?? (vertical ? 118 : 120);
  return (
    <Hit>
      <Clip src={src} from={from} zoom={zoom} vertical={vertical} tall={tall} pos={pos} />
      {top && (
        <AbsoluteFill style={{ justifyContent: vertical ? "flex-start" : "flex-end", alignItems: "center", padding: vertical ? "120px 40px 0" : "0 60px 70px" }}>
          <Slam text={top} size={size} delay={4} />
        </AbsoluteFill>
      )}
      {bottom && (
        <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center", padding: vertical ? "0 40px 90px" : "0 60px 70px", gap: 4 }}>
          {bottom.map((t, i) => (
            <Slam key={t} text={t} size={vertical ? 100 : 104} delay={6 + i * 14} color={i ? ACCENT : "#fff"} />
          ))}
        </AbsoluteFill>
      )}
    </Hit>
  );
};

const Hook: React.FC<{ vertical: boolean; t: (typeof T)["en"] }> = ({ vertical, t }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const scale = 1 + interpolate(frame, [0, durationInFrames], [0.02, 0.2]);
  return (
    <Hit>
      <AbsoluteFill style={{ background: DARK }}>
        <AbsoluteFill style={{ transform: `scale(${scale})` }}>
          <Img src={staticFile("keyart.jpg")} style={{ width: "100%", height: "100%", objectFit: "cover", objectPosition: vertical ? "62% 50%" : "50% 50%" }} />
        </AbsoluteFill>
        <Vignette />
        <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: vertical ? "center" : "flex-end", padding: vertical ? "0 30px 330px" : "0 70px 60px", gap: 4 }}>
          <Slam text={t.hook1} size={vertical ? 128 : 110} delay={18} />
          <Slam text={t.hook2} size={vertical ? 150 : 130} delay={42} color={ACCENT} />
        </AbsoluteFill>
      </AbsoluteFill>
    </Hit>
  );
};

const EndCard: React.FC<{ vertical: boolean; t: (typeof T)["en"] }> = ({ vertical, t }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const pop = spring({ frame: frame - 6, fps, config: { damping: 9, stiffness: 140 } });
  const pulse = 1 + Math.sin(frame / 5) * 0.025;
  return (
    <Hit>
      <AbsoluteFill style={{ background: DARK }}>
        <AbsoluteFill style={{ filter: "blur(30px) brightness(0.5)", transform: "scale(1.2)" }}>
          <Img src={staticFile("keyart.jpg")} style={{ width: "100%", height: "100%", objectFit: "cover" }} />
        </AbsoluteFill>
        <Vignette />
        <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", gap: vertical ? 40 : 28 }}>
          <Img
            src={staticFile("icon.png")}
            style={{
              width: vertical ? 420 : 340,
              height: vertical ? 420 : 340,
              borderRadius: 70,
              border: `6px solid ${ACCENT}`,
              boxShadow: `0 0 120px ${ACCENT}`,
              transform: `scale(${interpolate(pop, [0, 1], [0.2, 1])})`,
            }}
          />
          <Slam text="WW3: HIGH COMMAND" size={vertical ? 74 : 110} delay={14} />
          <div
            style={{
              fontFamily,
              fontSize: vertical ? 70 : 64,
              color: DARK,
              background: "#fff",
              padding: "16px 44px",
              borderRadius: 999,
              transform: `scale(${interpolate(pop, [0, 1], [0, 1]) * pulse})`,
              boxShadow: `0 0 60px ${ACCENT}`,
            }}
          >
            {t.free}
          </div>
          <div style={{ fontFamily, fontSize: vertical ? 44 : 40, color: "#fff", opacity: interpolate(frame, [40, 60], [0, 0.9], { extrapolateRight: "clamp" }), textShadow: `0 4px 0 ${DARK}` }}>
            {t.search}
          </div>
        </AbsoluteFill>
      </AbsoluteFill>
    </Hit>
  );
};

export const Promo: React.FC<PromoProps> = ({ lang, vertical }) => {
  const t = T[lang];
  const seq = (i: number, node: React.ReactNode) => (
    <Sequence from={CUTS[i]} durationInFrames={CUTS[i + 1] - CUTS[i]} layout="none">
      {node}
    </Sequence>
  );
  return (
    <AbsoluteFill style={{ background: DARK }}>
      <Audio src={staticFile("track.wav")} volume={0.95} />
      {seq(0, <Hook vertical={vertical} t={t} />)}
      {seq(1, <Shot vertical={vertical} src="world.mp4" from={50} top={t.pick} />)}
      {seq(2, <Shot vertical={vertical} src="spawn.mp4" from={50} bottom={[t.expand]} tall pos="48% 50%" />)}
      {seq(3, <Shot vertical={vertical} src="grow.mp4" from={0} bottom={[t.attack]} zoom={0.14} tall pos="40% 55%" />)}
      {seq(4, <Shot vertical={vertical} src="ui.mp4" from={30} top={t.build} topSize={vertical ? 82 : 96} />)}
      {seq(5, <Shot vertical={vertical} src="empire.mp4" from={215} bottom={[t.rule1, t.rule2]} zoom={0.16} tall pos="55% 50%" />)}
      {seq(6, <EndCard vertical={vertical} t={t} />)}
    </AbsoluteFill>
  );
};
