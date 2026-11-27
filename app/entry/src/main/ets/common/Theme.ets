import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { window } from '@kit.ArkUI';

export interface AppTheme {
  id: string;
  name: string;
  subtitle: string;
  isDark: boolean;
  previewBg: string;
  previewAccent: string;
  bg: string;
  bgSecondary: string;
  surface: string;
  surfaceMuted: string;
  surfaceSelected: string;
  navBg: string;
  navBgGlass: string;
  navBorder: string;
  navHighlight: string;
  navHighlightBorder: string;
  border: string;
  borderStrong: string;
  divider: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  accent: string;
  accentSoft: string;
  accentOn: string;
  success: string;
  successSoft: string;
  warning: string;
  warningSoft: string;
  danger: string;
  dangerSoft: string;
  powerIdleBg: string;
  powerIdleBorder: string;
  powerIdleIcon: string;
  powerRunBg: string;
  powerRunBorder: string;
  shadow: string;
}

export const THEME_DARK: AppTheme = {
  id: 'dark',
  name: '静夜深灰',
  subtitle: '素雅沉静炭灰深色',
  isDark: true,
  previewBg: '#12151C',
  previewAccent: '#4B8BFF',
  bg: '#0E1117',
  bgSecondary: '#0E1117',
  surface: '#171B24',
  surfaceMuted: '#11151D',
  surfaceSelected: '#1C2536',
  navBg: '#D6181D27',
  navBgGlass: '#14000000',
  navBorder: '#33FFFFFF',
  navHighlight: '#2EFFFFFF',
  navHighlightBorder: '#3DFFFFFF',
  border: '#14FFFFFF',
  borderStrong: '#26FFFFFF',
  divider: '#12FFFFFF',
  textPrimary: '#F2F4F8',
  textSecondary: '#94A0B4',
  textTertiary: '#637085',
  accent: '#4B8BFF',
  accentSoft: '#1E4B8BFF',
  accentOn: '#FFFFFF',
  success: '#10B981',
  successSoft: '#1A10B981',
  warning: '#F59E0B',
  warningSoft: '#1AF59E0B',
  danger: '#EF4444',
  dangerSoft: '#1AEF4444',
  powerIdleBg: '#191E29',
  powerIdleBorder: '#273042',
  powerIdleIcon: '#E8EDF5',
  powerRunBg: '#112922',
  powerRunBorder: '#10B981',
  shadow: '#38000000'
};

export const THEME_LIGHT: AppTheme = {
  id: 'light',
  name: '素白浅色',
  subtitle: '纯净通透纸白外观',
  isDark: false,
  previewBg: '#F6F7F9',
  previewAccent: '#2563EB',
  bg: '#F6F7F9',
  bgSecondary: '#F6F7F9',
  surface: '#FFFFFF',
  surfaceMuted: '#EEF1F6',
  surfaceSelected: '#EDF3FF',
  navBg: '#CCFFFFFF',
  navBgGlass: '#12FFFFFF',
  navBorder: '#88FFFFFF',
  navHighlight: '#242563EB',
  navHighlightBorder: '#332563EB',
  border: '#E5E9F0',
  borderStrong: '#CBD3E1',
  divider: '#ECEFF5',
  textPrimary: '#131722',
  textSecondary: '#5A6577',
  textTertiary: '#8A94A6',
  accent: '#2563EB',
  accentSoft: '#1A2563EB',
  accentOn: '#FFFFFF',
  success: '#059669',
  successSoft: '#E7F8F1',
  warning: '#D97706',
  warningSoft: '#FEF3C7',
  danger: '#DC2626',
  dangerSoft: '#FEE2E2',
  powerIdleBg: '#FFFFFF',
  powerIdleBorder: '#DCE2EC',
  powerIdleIcon: '#1E2533',
  powerRunBg: '#ECFDF5',
  powerRunBorder: '#10B981',
  shadow: '#18182233'
};

export const THEME_OLED: AppTheme = {
  id: 'oled',
  name: '极简纯黑',
  subtitle: 'OLED 纯黑低功耗',
  isDark: true,
  previewBg: '#000000',
  previewAccent: '#E5E7EB',
  bg: '#000000',
  bgSecondary: '#000000',
  surface: '#111215',
  surfaceMuted: '#090A0C',
  surfaceSelected: '#1C1E24',
  navBg: '#D914161A',
  navBgGlass: '#14000000',
  navBorder: '#2EFFFFFF',
  navHighlight: '#2AFFFFFF',
  navHighlightBorder: '#38FFFFFF',
  border: '#16FFFFFF',
  borderStrong: '#28FFFFFF',
  divider: '#14FFFFFF',
  textPrimary: '#F5F6F8',
  textSecondary: '#8F96A3',
  textTertiary: '#5D6470',
  accent: '#60A5FA',
  accentSoft: '#1E60A5FA',
  accentOn: '#FFFFFF',
  success: '#10B981',
  successSoft: '#1810B981',
  warning: '#F59E0B',
  warningSoft: '#1AF59E0B',
  danger: '#EF4444',
  dangerSoft: '#1AEF4444',
  powerIdleBg: '#121318',
  powerIdleBorder: '#242730',
  powerIdleIcon: '#F3F4F6',
  powerRunBg: '#0C211B',
  powerRunBorder: '#10B981',
  shadow: '#40000000'
};

export const THEME_SAGE_LIGHT: AppTheme = {
  id: 'sage_light',
  name: '青岚浅绿',
  subtitle: '淡雅松雾浅色主题',
  isDark: false,
  previewBg: '#F2F7F5',
  previewAccent: '#0F766E',
  bg: '#F2F7F5',
  bgSecondary: '#F2F7F5',
  surface: '#FFFFFF',
  surfaceMuted: '#E8F0ED',
  surfaceSelected: '#E6F4F1',
  navBg: '#CCFFFFFF',
  navBgGlass: '#14FFFFFF',
  navBorder: '#88FFFFFF',
  navHighlight: '#220F766E',
  navHighlightBorder: '#330F766E',
  border: '#DCE7E3',
  borderStrong: '#BFD2CB',
  divider: '#E6EFEC',
  textPrimary: '#10211D',
  textSecondary: '#4D635D',
  textTertiary: '#7B918B',
  accent: '#0F766E',
  accentSoft: '#180F766E',
  accentOn: '#FFFFFF',
  success: '#059669',
  successSoft: '#E6F7F1',
  warning: '#D97706',
  warningSoft: '#FEF3C7',
  danger: '#DC2626',
  dangerSoft: '#FEE2E2',
  powerIdleBg: '#FFFFFF',
  powerIdleBorder: '#CFE0DA',
  powerIdleIcon: '#16302A',
  powerRunBg: '#E6F7F1',
  powerRunBorder: '#059669',
  shadow: '#160E2A24'
};

export const THEME_SLATE_DARK: AppTheme = {
  id: 'slate_dark',
  name: '暮蓝雾灰',
  subtitle: '柔和冷雾深灰蓝',
  isDark: true,
  previewBg: '#131A24',
  previewAccent: '#38BDF8',
  bg: '#111720',
  bgSecondary: '#111720',
  surface: '#1A222F',
  surfaceMuted: '#131A25',
  surfaceSelected: '#202D40',
  navBg: '#D61A2230',
  navBgGlass: '#14000000',
  navBorder: '#36FFFFFF',
  navHighlight: '#2A38BDF8',
  navHighlightBorder: '#4438BDF8',
  border: '#18FFFFFF',
  borderStrong: '#2CFFFFFF',
  divider: '#14FFFFFF',
  textPrimary: '#F1F5F9',
  textSecondary: '#94A3B8',
  textTertiary: '#64748B',
  accent: '#38BDF8',
  accentSoft: '#1F38BDF8',
  accentOn: '#08131E',
  success: '#34D399',
  successSoft: '#1A34D399',
  warning: '#FBBF24',
  warningSoft: '#1AFBBF24',
  danger: '#F87171',
  dangerSoft: '#1AF87171',
  powerIdleBg: '#1C2534',
  powerIdleBorder: '#2C3A50',
  powerIdleIcon: '#E2E8F0',
  powerRunBg: '#102A28',
  powerRunBorder: '#34D399',
  shadow: '#38000000'
};

export const ALL_THEMES: AppTheme[] = [
  THEME_LIGHT,
  THEME_DARK,
  THEME_OLED,
  THEME_SAGE_LIGHT,
  THEME_SLATE_DARK
];

const THEME_PREF_FILE: string = 'xray_prefs';
const THEME_PREF_KEY: string = 'uiThemeId';

export function themeById(id: string): AppTheme {
  for (const t of ALL_THEMES) {
    if (t.id === id) {
      return t;
    }
  }
  return THEME_DARK;
}

export async function loadSavedThemeId(context: common.Context): Promise<string> {
  try {
    const store = await preferences.getPreferences(context, THEME_PREF_FILE);
    const saved: string = store.getSync(THEME_PREF_KEY, 'dark') as string;
    return themeById(saved).id;
  } catch (error) {
    return 'dark';
  }
}

export async function saveThemeId(context: common.Context, id: string): Promise<void> {
  try {
    const store = await preferences.getPreferences(context, THEME_PREF_FILE);
    store.putSync(THEME_PREF_KEY, themeById(id).id);
    await store.flush();
  } catch (error) {
  }
}

export async function syncWindowBars(context: common.Context, theme: AppTheme): Promise<void> {
  try {
    const win: window.Window = await window.getLastWindow(context);
    await win.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: theme.isDark ? '#FFFFFFFF' : '#FF131722',
      navigationBarContentColor: theme.isDark ? '#FFFFFFFF' : '#FF131722'
    });
  } catch (error) {
  }
}
