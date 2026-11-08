import React from "react";
import { Composition } from "remotion";
import { Promo } from "./Promo";

export const Root: React.FC = () => (
  <>
    <Composition id="ShortEN" component={Promo} durationInFrames={900} fps={30} width={1080} height={1920} defaultProps={{ lang: "en" as const, vertical: true }} />
    <Composition id="ShortRU" component={Promo} durationInFrames={900} fps={30} width={1080} height={1920} defaultProps={{ lang: "ru" as const, vertical: true }} />
    <Composition id="TrailerEN" component={Promo} durationInFrames={900} fps={30} width={1920} height={1080} defaultProps={{ lang: "en" as const, vertical: false }} />
    <Composition id="TrailerRU" component={Promo} durationInFrames={900} fps={30} width={1920} height={1080} defaultProps={{ lang: "ru" as const, vertical: false }} />
  </>
);
