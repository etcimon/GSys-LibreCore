import type { SidebarsConfig } from '@docusaurus/plugin-content-docs';


const sidebars: SidebarsConfig = {
  documentation: [
    {
      type: 'category',
      label: 'Getting Started',
      items: [
        'documentation/getting-started/introduction/index',
        'documentation/getting-started/reactive-programming/index',
        'documentation/getting-started/installation/index',
      ],
    },
    {
      type: 'category',
      label: 'Component',
      items: [
        {
          type: 'doc',
          label: 'Introduction',
          id: 'documentation/component/component/index',
        },
        {
          type: 'link',
          label: 'Styling',
          href: '/docs/documentation/component/component/#style',
        },
        {
          type: 'doc',
          label: 'Lifecycle',
          id: 'documentation/component/lifecycle/index',
        },
        {
          type: 'doc',
          label: 'Inputs and Outputs',
          id: 'documentation/component/inputs-outputs/index',
        },
        {
          type: 'link',
          label: 'Slots',
          href: '/docs/documentation/syntax/custom-element/#slotting---ak-provide-templates-to-our-components',
        },
      ],
    },
    {
      type: 'category',
      label: 'Template Syntax',
      link: {
        type: 'doc',
        id: 'documentation/syntax/index',
      },
      items: [
        'documentation/syntax/reactive-value/index',
        'documentation/syntax/reactive-text/index',
        {
          type: 'category',
          label: 'Attributes',
          items: [
            {
              type: 'category',
              label: 'Bind',
              link: {
                type: 'doc',
                id: 'documentation/syntax/attributes/bind/index',
              },
              items: [
                'documentation/syntax/attributes/bind/reactive-class/index',
                'documentation/syntax/attributes/bind/reactive-class-list/index',
                'documentation/syntax/attributes/bind/reactive-style/index',
                'documentation/syntax/attributes/bind/reactive-style-list/index',
                'documentation/syntax/attributes/bind/reactive-property/index',
                'documentation/syntax/attributes/bind/reactive-attribute/index',
                'documentation/syntax/attributes/bind/reactive-input/index',
              ],
            },
            {
              type: 'category',
              label: 'Event',
              link: {
                type: 'doc',
                id: 'documentation/syntax/attributes/event/index',
              },
              items: [
                'documentation/syntax/attributes/event/event-listener/index',
                'documentation/syntax/attributes/event/reactive-output/index',
              ],
            },
            'documentation/syntax/attributes/modifier/index',
          ],
        },
        {
          type: 'category',
          label: 'RX Components',
          link: {
            type: 'doc',
            id: 'documentation/syntax/rx-components/index',
          },
          items: [
            'documentation/syntax/rx-components/rx-container/index',
            'documentation/syntax/rx-components/rx-template/index',
            'documentation/syntax/rx-components/rx-inject-template/index',
            'documentation/syntax/rx-components/rx-if/index',
            'documentation/syntax/rx-components/rx-switch/index',
            'documentation/syntax/rx-components/rx-for-loop/index',
            'documentation/syntax/rx-components/rx-async/index',
          ],
        },
        'documentation/syntax/custom-element/index',
      ],
    },
    {
      type: 'doc',
      label: '🚧 Virtual DOM',
      id: 'documentation/virtual-dom/index',
    },
    {
      type: 'link',
      label: 'Examples',
      href: 'https://github.com/lirx-js/dom-examples',
    },
    {
      type: 'doc',
      label: 'AOT compiler',
      id: 'documentation/aot-compiler/index',
    },
    // {
    //   type: 'category',
    //   label: 'Router',
    //   link: {
    //     type: 'doc',
    //     id: 'documentation/router/index',
    //   },
    //   items: [
    //     // TODO
    //     'documentation/syntax/attributes/bind/reactive-class/index',
    //   ],
    // },
    // {
    //   type: 'category',
    //   label: 'CLI',
    //   link: {
    //     type: 'doc',
    //     id: 'documentation/cli/index',
    //   },
    //   items: [
    //     // TODO
    //     'documentation/syntax/attributes/bind/reactive-class/index',
    //   ],
    // },
    // {
    //   type: 'category',
    //   label: 'Material UI',
    //   link: {
    //     type: 'doc',
    //     id: 'documentation/material/index',
    //   },
    //   items: [
    //     {
    //       type: 'doc',
    //       label: 'UI',
    //       id: 'documentation/material/ui',
    //     },
    //     {
    //       type: 'doc',
    //       label: 'Icons',
    //       id: 'documentation/material/icons',
    //     }
    //   ],
    // },
    {
      type: 'category',
      label: 'Comparisons',
      items: [
        'documentation/comparisons/introduction/index',
        {
          type: 'category',
          label: 'Benchmarks',
          items: [
            'documentation/comparisons/benchmarks/file-to-data-url/index',
            'documentation/comparisons/benchmarks/complex-app/index',
          ],
        },
        'documentation/comparisons/vs-angular/index',
        'documentation/comparisons/vs-react/index',
      ],
    },
  ],
  reference: [
    {
      type: 'autogenerated',
      dirName: 'reference',
    },
  ],
  changelogs: [
    {
      type: 'autogenerated',
      dirName: 'changelogs',
    },
  ],
};

export default sidebars;
