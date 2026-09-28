// ============================================================
// lib/fish-icons.js — 簡筆風魚類 SVG icon 系統
// 目的：取代 AI 生成的 PNG 魚照，避免被誤認為 AI 內容
// 風格：線條插畫風，幾何形狀 + 顏色區分，簡單斑紋標記
// 大小：viewBox 80x80，可縮放
// 用法：fishIconSvg('泥鯭', 80) → SVG 字串
// ============================================================

// 15 種香港常見魚的配色 + 斑紋定義
const FISH_PRESETS = {
  '泥鯭':     { primary: '#6B7280', secondary: '#9CA3AF', accent: '#1F2937', dorsal: '#1F2937', pattern: 'dots',   desc: '群居，背鰭有毒刺' },
  '黑沙鱲':   { primary: '#374151', secondary: '#A1A1AA', accent: '#18181B', dorsal: '#27272A', pattern: 'plain',  desc: '力大善搏，磯釣常見' },
  '黃腳鱲':   { primary: '#A8A29E', secondary: '#E7E5E4', accent: '#F59E0B', dorsal: '#D97706', pattern: 'plain',  desc: '雜食性，磯釣主力' },
  '牛屎鱲':   { primary: '#A8A29E', secondary: '#E7E5E4', accent: '#27272A', dorsal: '#78716C', pattern: 'dots',   desc: '小型魚，淺灘常見' },
  '白鱲':     { primary: '#E5E7EB', secondary: '#F9FAFB', accent: '#6B7280', dorsal: '#9CA3AF', pattern: 'plain',  desc: '底棲魚，礁石沙底交界' },
  '石狗公':   { primary: '#DC2626', secondary: '#FCA5A5', accent: '#7F1D1D', dorsal: '#7F1D1D', pattern: 'spiny',  desc: '底棲伏擊，背鰭有毒刺' },
  '烏頭':     { primary: '#78716C', secondary: '#D6D3D1', accent: '#44403C', dorsal: '#44403C', pattern: 'plain',  desc: '蠔排主力魚' },
  '沙鑽':     { primary: '#CBD5E1', secondary: '#F1F5F9', accent: '#64748B', dorsal: '#94A3B8', pattern: 'slim',   desc: '吻尖體長，沙底群居' },
  '牛鰍':     { primary: '#92400E', secondary: '#D97706', accent: '#78350F', dorsal: '#78350F', pattern: 'flat',   desc: '底棲伏擊，沙泥底常見' },
  '紅衫':     { primary: '#EF4444', secondary: '#FCA5A5', accent: '#7F1D1D', dorsal: '#7F1D1D', pattern: 'stripe', desc: '體色偏紅，淺海常見' },
  '丁公':     { primary: '#9CA3AF', secondary: '#E5E7EB', accent: '#1F2937', dorsal: '#1F2937', pattern: 'stripe', desc: '條紋雞魚，背鰭有黑斑' },
  '火點':     { primary: '#DC2626', secondary: '#FEE2E2', accent: '#7F1D1D', dorsal: '#7F1D1D', pattern: 'spots',  desc: '夜間活躍，珊瑚礁伏擊' },
  '沙鯭':     { primary: '#CBD5E1', secondary: '#F1F5F9', accent: '#F59E0B', dorsal: '#D97706', pattern: 'plain',  desc: '沙底群居，灘釣常見' },
  '金鯧':     { primary: '#F59E0B', secondary: '#FCD34D', accent: '#92400E', dorsal: '#92400E', pattern: 'fan',    desc: '銀身黃尾，肉質細嫩' },
  '金鼓':     { primary: '#94A3B8', secondary: '#CBD5E1', accent: '#475569', dorsal: '#475569', pattern: 'round',  desc: '半鹹淡水棲，背鰭有毒' },
};

// 不同魚形的 base path
// normal: 標準橢圓魚
// slim:   細長魚（沙鑽）
// flat:   扁身魚（牛鰍）
// round:  鼓身魚（金鼓）
function fishBasePath(shape) {
  switch(shape) {
    case 'slim':
      return `
        <path d="M 8 40 Q 18 28, 40 28 Q 60 28, 64 40 Q 60 52, 40 52 Q 18 52, 8 40 Z" fill="var(--body)" stroke="var(--dorsal)" stroke-width="2.5" stroke-linejoin="round"/>
        <path d="M 64 40 L 76 32 L 74 40 L 76 48 Z" fill="var(--fin)" stroke="var(--dorsal)" stroke-width="2" stroke-linejoin="round"/>
        <circle cx="22" cy="38" r="2" fill="var(--dorsal)"/><circle cx="22" cy="38" r="0.9" fill="#FFFFFF"/>
        <path d="M 28 46 L 36 48" stroke="var(--dorsal)" stroke-width="1.2" fill="none" stroke-linecap="round"/>`;
    case 'flat':
      return `
        <path d="M 8 44 Q 14 36, 30 36 L 56 38 Q 64 40, 64 44 Q 64 48, 56 50 L 30 52 Q 14 52, 8 44 Z" fill="var(--body)" stroke="var(--dorsal)" stroke-width="2.5" stroke-linejoin="round"/>
        <path d="M 64 44 L 76 36 L 74 44 L 76 52 Z" fill="var(--fin)" stroke="var(--dorsal)" stroke-width="2" stroke-linejoin="round"/>
        <circle cx="20" cy="40" r="2.2" fill="var(--dorsal)"/><circle cx="20" cy="40" r="0.9" fill="#FFFFFF"/>
        <path d="M 30 44 L 50 44" stroke="var(--dorsal)" stroke-width="1" fill="none" opacity="0.5"/>`;
    case 'round':
      return `
        <path d="M 10 40 Q 16 22, 36 22 Q 58 22, 62 40 Q 58 58, 36 58 Q 16 58, 10 40 Z" fill="var(--body)" stroke="var(--dorsal)" stroke-width="2.5" stroke-linejoin="round"/>
        <path d="M 62 40 L 76 28 L 72 40 L 76 52 Z" fill="var(--fin)" stroke="var(--dorsal)" stroke-width="2" stroke-linejoin="round"/>
        <circle cx="22" cy="36" r="2.5" fill="var(--dorsal)"/><circle cx="22" cy="36" r="1.1" fill="#FFFFFF"/>
        <path d="M 26 44 Q 32 48, 38 44" stroke="var(--dorsal)" stroke-width="1.5" fill="none" stroke-linecap="round"/>`;
    case 'normal':
    default:
      return `
        <path d="M 8 40 Q 16 22, 38 22 Q 58 22, 62 40 Q 58 58, 38 58 Q 16 58, 8 40 Z" fill="var(--body)" stroke="var(--dorsal)" stroke-width="2.5" stroke-linejoin="round"/>
        <path d="M 62 40 L 76 28 L 72 40 L 76 52 Z" fill="var(--fin)" stroke="var(--dorsal)" stroke-width="2" stroke-linejoin="round"/>
        <circle cx="22" cy="36" r="2.5" fill="var(--dorsal)"/><circle cx="22" cy="36" r="1.1" fill="#FFFFFF"/>
        <path d="M 26 46 Q 32 50, 38 46" stroke="var(--dorsal)" stroke-width="1.5" fill="none" stroke-linecap="round"/>`;
  }
}

// 魚形決定：根據 pattern/preset 自動選擇
function getFishShape(pattern) {
  if (pattern === 'slim') return 'slim';
  if (pattern === 'flat') return 'flat';
  if (pattern === 'round') return 'round';
  return 'normal';
}

// 不同斑紋的 overlay（簡筆插畫的細節標記）
function fishPatternOverlay(pattern, accent) {
  switch(pattern) {
    case 'dots':
      return `<circle cx="32" cy="32" r="2" fill="${accent}"/>
              <circle cx="44" cy="48" r="2" fill="${accent}"/>
              <circle cx="52" cy="36" r="2" fill="${accent}"/>`;
    case 'spots':
      return `<circle cx="30" cy="32" r="1.5" fill="#FFFFFF" stroke="${accent}" stroke-width="0.8"/>
              <circle cx="40" cy="46" r="1.5" fill="#FFFFFF" stroke="${accent}" stroke-width="0.8"/>
              <circle cx="52" cy="34" r="1.5" fill="#FFFFFF" stroke="${accent}" stroke-width="0.8"/>
              <circle cx="46" cy="50" r="1.5" fill="#FFFFFF" stroke="${accent}" stroke-width="0.8"/>`;
    case 'stripe':
      return `<path d="M 26 28 Q 28 40, 26 52" stroke="${accent}" stroke-width="1.8" fill="none" stroke-linecap="round"/>
              <path d="M 36 26 Q 38 40, 36 54" stroke="${accent}" stroke-width="1.8" fill="none" stroke-linecap="round"/>
              <path d="M 46 28 Q 48 40, 46 52" stroke="${accent}" stroke-width="1.8" fill="none" stroke-linecap="round"/>`;
    case 'spiny':
      return `<path d="M 18 26 L 22 18 L 26 26" stroke="${accent}" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
              <path d="M 30 23 L 34 14 L 38 23" stroke="${accent}" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
              <path d="M 42 23 L 46 16 L 50 24" stroke="${accent}" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
              <path d="M 54 25 L 58 20 L 62 28" stroke="${accent}" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>`;
    case 'fan':
      return `<path d="M 52 22 L 56 14 L 60 22" stroke="${accent}" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
              <path d="M 56 14 L 60 22 L 64 14" stroke="${accent}" stroke-width="1.5" fill="none" stroke-linecap="round"/>`;
    case 'round':
      return `<ellipse cx="40" cy="40" rx="22" ry="13" fill="none" stroke="${accent}" stroke-width="1.2" stroke-dasharray="3,2"/>`;
    case 'flat':
      return `<path d="M 16 42 L 36 42" stroke="${accent}" stroke-width="1" fill="none" opacity="0.5"/>
              <path d="M 16 46 L 36 46" stroke="${accent}" stroke-width="1" fill="none" opacity="0.5"/>`;
    default:
      return '';
  }
}

// 對外接口：根據魚名 + 大小回傳 SVG 字串
function fishIconSvg(name, size = 80) {
  const preset = FISH_PRESETS[name] || { primary: '#9CA3AF', secondary: '#D1D5DB', accent: '#374151', dorsal: '#1F2937', pattern: 'plain' };
  const shape = getFishShape(preset.pattern);
  return `<svg viewBox="0 0 80 80" width="${size}" height="${size}" xmlns="http://www.w3.org/2000/svg" style="display:block;" aria-hidden="true">
  <g style="--body:${preset.primary};--fin:${preset.secondary};--dorsal:${preset.dorsal};">
    ${fishBasePath(shape)}
    ${fishPatternOverlay(preset.pattern, preset.accent)}
  </g>
</svg>`.trim();
}

// 全域暴露（無模組系統時用 window）
if (typeof window !== 'undefined') {
  window.fishIconSvg = fishIconSvg;
  window.FISH_PRESETS = FISH_PRESETS;
}