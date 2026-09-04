# Contributing

This projet is open to everyone. Feel free to test the library, share it, improve it, and create merge requests.

### Structure of the project

#### Root

The library requires `nodejs 19+`, `yarn` and optionally `verdaccio` (if not required, you may comment the `.yarnrc` file. See later the explanation).

So the first commands to run are:

```shell
nvm use
```

*If you don't have nvm, please use manually nodejs 19+.*

Then:

```shell
yarn install
```

#### Source code

The source code is located in the `src` directory.
This is where you'll find the core components, functions, classes and types of the library.

#### Build

This library contains a specific folder called `build`.
It contains all the scripts to build the library, develop it, and some common operations.

```shell
cd build
yarn install
```

To build the lib: `yarn run build`. It will create an `esm` and a `cjs` version of the library with type definitions.
The resulting build is compatible with modern and old bundlers, and is located in the `dist` directory.

To develop, you'll need `verdaccio`. You can install it using:

```shell
npm install --global verdaccio
# or yarn run install:verdaccio
```

And then run it:

```shell
verdaccio
# or yarn run run:verdaccio
```

`verdaccio` is used to share locally the package and test it from other projets.

Then to build and publish the lib to `verdaccio`:

```shell
yarn build:dev
```

The `build` folder must be kept untouched, but you can submit changes [here](https://github.com/lifaon74/ts-lib-seed).

#### Website

This directory (`website`) contains the documentation of this library.

First run:

```shell
yarn install
```

And then:

```shell
yarn start
```
