import type { Options, ThemeConfig } from '@docusaurus/preset-classic';
import type { Config } from '@docusaurus/types';

import darkCodeTheme from './themes/prism/dracula';
import lightCodeTheme from './themes/prism/github';

const organizationName = 'lirx-js';
const projectName = 'dom';

const githubURL = `https://github.com/${organizationName}/${projectName}/`;

const config: Config = {
  title: 'LiRX/dom',
  tagline: 'The Reactive Programming Web Framework',
  url: 'https://dom.lirx.org',
  baseUrl: '/',
  onBrokenLinks: 'throw',
  onBrokenMarkdownLinks: 'warn',
  favicon: 'img/logos/favicon.ico',

  // github
  organizationName,
  projectName,
  trailingSlash: true,

  // i18n
  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
    // locales: ['en', 'fr'],
    // localeConfigs: {
    //   en: {
    //     htmlLang: 'en-GB',
    //   },
    // },
  },

  markdown: {
    format: 'mdx',
    mermaid: true,
    // mdx1Compat: {
    //   comments: true,
    //   admonitions: true,
    //   headingIds: true,
    // },
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: require.resolve('./sidebars.js'),
          editUrl: `${githubURL}tree/main/website`,
        },
        blog: {
          showReadingTime: true,
          editUrl: `${githubURL}tree/main/website`,
        },
        theme: {
          customCss: require.resolve('./src/css/custom.css'),
        },
      } satisfies Options,
    ],
  ],

  themeConfig: {
    metadata: [
      {
        name: 'keywords',
        content: 'Reactive Programming, framework, web, ui',
      },
    ],
    colorMode: {
      defaultMode: 'dark',
      disableSwitch: false,
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'LiRX/dom',
      logo: {
        alt: 'LiRX/dom Logo',
        src: 'img/logos/lirx-dom-logo.png',
      },
      items: [
        {
          label: 'Docs',
          type: 'docSidebar',
          sidebarId: 'documentation',
          position: 'left',
        },
        {
          label: 'Syntax',
          to: '/docs/documentation/syntax/rx-components/',
          position: 'left',
        },
        {
          label: 'Reference',
          type: 'docSidebar',
          sidebarId: 'reference',
          position: 'left',
        },
        {
          label: 'Blog',
          to: '/blog',
          position: 'left',
        },
        {
          label: 'GitHub',
          href: githubURL,
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Learn',
          items: [
            {
              label: 'Introduction',
              to: '/docs/documentation/getting-started/introduction/',
            },
            {
              label: 'Examples',
              to: 'https://github.com/lirx-js/dom-examples',
            },
          ],
        },
        // {
        //   title: 'Community',
        //   items: [
        //     {
        //       label: 'Ask for a functionality',
        //       href: 'https://github.com/lirx-js/core/discussions',
        //     },
        //   ],
        // },
        {
          title: 'Ecosystem',
          items: [
            {
              label: 'LiRX/core',
              href: 'https://core.lirx.org',
            },
            {
              label: 'LiRX/dom',
              href: 'https://dom.lirx.org',
            },
            {
              label: 'LiRX/router',
              // href: 'https://router.lirx.org',
              href: 'https://github.com/lirx-js/router',
            },
            {
              label: 'LiRX/i18n',
              // href: 'https://i18n.lirx.org',
              href: 'https://github.com/lirx-js/i18n',
            },
            {
              label: 'LiRX/store',
              // href: 'https://store.lirx.org',
              href: 'https://github.com/lirx-js/store',
            },
          ],
        },
        {
          title: 'More',
          items: [
            {
              label: 'Blog',
              to: '/blog/',
            },
            {
              label: 'Changelog',
              to: '/docs/changelogs/0.9.0/',
            },
            {
              label: 'GitHub',
              href: githubURL,
            },
            {
              label: 'Ask for a functionality',
              href: `${githubURL}discussions`,
            },
          ],
        },
        // {
        //   title: 'More',
        //   items: [
        //     {
        //       label: 'Blog',
        //       to: '/blog',
        //     },
        //     {
        //       label: 'GitHub',
        //       href: 'https://github.com/facebook/docusaurus',
        //     },
        //   ],
        // },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} @lirx/dom, owned by Valentin Richard and maintained with love by all the community ♥.`,
    },
    prism: {
      theme: lightCodeTheme,
      darkTheme: darkCodeTheme,
    },
    mermaid: {
      theme: {
        // https://mermaid.js.org/config/theming.html
        // default, neutral, dark, forest, base
        light: 'default',
        dark: 'dark',
      },
    },
  }  satisfies ThemeConfig,
  plugins: [
    // // https://github.com/cmfcmf/docusaurus-search-local
    // require.resolve('@cmfcmf/docusaurus-search-local'),
  ],
  themes: [
    '@docusaurus/theme-mermaid',
    [
      require.resolve('@easyops-cn/docusaurus-search-local'),
      {
        hashed: true,
      },
    ],
  ],
};

export default config;
