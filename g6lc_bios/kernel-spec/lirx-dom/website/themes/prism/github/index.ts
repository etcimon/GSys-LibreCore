import { PrismTheme } from '@site/node_modules/prism-react-renderer';

// https://github.com/PrismJS/prism-themes
// Original: https://github.com/PrismJS/prism-themes/blob/master/themes/prism-darcula.css
// Converted automatically using ./tools/themeFromVsCode

const theme: PrismTheme = {
  plain: {
    color: '#24292f',
    backgroundColor: '#f6f8fa',
  },
  styles: [
    {
      types: ['keyword'],
      style: {
        color: '#cf222e',
      },
    },
    {
      types: ['comment', 'prolog', 'cdata'],
      style: {
        color: '#6e7781',
      },
    },
    {
      types: ['operator', 'boolean', 'number', 'regex', 'doctype', 'attr-name', 'url', 'property'],
      style: {
        color: '#0550ae',
      },
    },
    {
      types: ['punctuation', 'builtin', 'at', 'entity', 'symbol'],
      style: {
        color: '#24292f',
      },
    },
    {
      types: ['function'],
      style: {
        color: '#8250df',
      },
    },
    {
      types: ['string', 'char', 'attr-value'],
      style: {
        color: '#0a3069',
      },
    },
    {
      types: ['tag'],
      style: {
        color: '#116329',
      },
    },
    {
      types: ['important', 'unit'],
      style: {
        color: '#cf222e',
      },
    },
    {
      types: ['variable'],
      style: {
        color: '#953800',
      },
    },
    // custom
    {
      types: ['bold'],
      style: {
        fontWeight: 'bold',
      },
    },
    {
      types: ['italic'],
      style: {
        fontStyle: 'italic',
      },
    },
    {
      types: ['inserted'],
      style: {
        backgroundColor: '#294436',
      },
    },
    {
      types: ['deleted'],
      style: {
        backgroundColor: '#484a4a',
      },
    },
// unknown
//     {
//       types: ['delimiter', 'selector', 'atrule'],
//       style: {
//         color: '#cf222e',
//       },
//     },
//     {
//       types: ['constant'],
//       style: {
//         color: '#9876aa',
//       },
//     },
  ],
};

export default theme;
