import { PrismTheme } from '@site/node_modules/prism-react-renderer';

// https://github.com/PrismJS/prism-themes
// Original: https://github.com/PrismJS/prism-themes/blob/master/themes/prism-darcula.css
// Converted automatically using ./tools/themeFromVsCode

const theme: PrismTheme = {
  plain: {
    color: '#F8F8F2',
    backgroundColor: '#2b2b2b',
  },
  styles: [
    {
      types: ['comment', 'prolog', 'cdata'],
      style: {
        color: '#808080',
      },
    },
    {
      types: ['delimiter', 'boolean', 'keyword', 'selector', 'important', 'atrule'],
      style: {
        color: '#cc7832',
      },
    },
    {
      types: ['operator', 'punctuation', 'attr-name'],
      style: {
        color: '#a9b7c6',
      },
    },
    {
      types: ['tag', 'doctype', 'builtin'], // tag .punctuation
      style: {
        color: '#e8bf6a',
      },
    },
    {
      types: ['entity', 'number', 'symbol'],
      style: {
        color: '#6897bb',
      },
    },
    {
      types: ['property', 'constant', 'variable'],
      style: {
        color: '#9876aa',
      },
    },
    {
      types: ['string', 'char'],
      style: {
        color: '#6a8759',
      },
    },
    {
      types: ['attr-value'], // attr-value .punctuation
      style: {
        color: '#a5c261',
      },
    },
    // {
    //   types: ['string', 'char'], // attr-value .punctuation:first-child
    //   style: {
    //     color: '#a9b7c6',
    //   },
    // },
    {
      types: ['url'],
      style: {
        color: '#287bde',
        textDecorationLine: 'underline',
      },
    },
    {
      types: ['function'],
      style: {
        color: '#ffc66d',
      },
    },
    {
      types: ['regex'],
      style: {
        backgroundColor: '#364135',
      },
    },
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
  ],
};

export default theme;
