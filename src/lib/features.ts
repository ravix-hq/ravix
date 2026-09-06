/** Build-time opt-in for the shared browser and Android/iOS preview UI. */
export const experimentalPreviews = import.meta.env.VITE_EXPERIMENTAL_PREVIEWS === "1";
