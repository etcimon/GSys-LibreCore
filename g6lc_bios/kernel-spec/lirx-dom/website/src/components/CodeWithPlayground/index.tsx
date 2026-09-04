import React from 'react';

export default function CodeWithPlayground({ children, link }): JSX.Element {
  return (
    <p>
      { children }
      <a href={link} target="_blank" rel="noopener noreferrer">Click here to see the live demo</a>
    </p>
  );
}



// <CodeWithPlayground link={'https://stackblitz.com/edit/typescript-9swej8?devtoolsheight=33&file=index.ts'}>
//
//   ```ts
//   const subscribe = single('Hello World !');
//
//   subscribe((value) => {
//   console.log(value);
// });
//   // logs 'Hello World !'
//   ```
//
// </CodeWithPlayground>
