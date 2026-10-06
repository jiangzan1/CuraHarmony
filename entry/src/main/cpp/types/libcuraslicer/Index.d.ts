export const ping: () => string;
export const getEngineInfo: () => string;
export const slice: (settingsPath: string, modelPaths: string[], outputPath: string, logPath?: string) => Promise<number>;
