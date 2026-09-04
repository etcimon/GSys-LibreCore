import React from 'react';
import clsx from 'clsx';
import styles from './styles.module.css';

type FeatureItem = {
  title: string;
  Svg: React.ComponentType<React.ComponentProps<'svg'>>;
  description: JSX.Element;
};

const FeatureList: FeatureItem[] = [
  {
    title: 'Designed to be fast',
    Svg: require('@site/static/img/illustrations/undraw/blue/undraw_the_world_is_mine_re_j5cr.svg').default,
    description: (
      <>
        LiRX/dom is a framework to create performant web applications, purely based on reactive programming:
        update only what's required and nothing more.
      </>
    ),
  },
  {
    title: 'A Complete Framework',
    Svg: require('@site/static/img/illustrations/undraw/blue/undraw_aircraft_re_m05i.svg').default,
    description: (
      <>
        Embeds everything you need: a router, an aot compiler, and a bundler.
        It supports typescript and scss right out of the box.
        All the essentials parts are included !
      </>
    ),
  },
  {
    title: 'Build small or large applications',
    Svg: require('@site/static/img/illustrations/undraw/blue/undraw_building_blocks_re_5ahy.svg').default,
    description: (
      <>
        Assemble your components from a small and simple application to the largest and complete one.
        Your imagination is the only limit.
      </>
    ),
  },
  // {
  //   title: 'Focus on What Matters',
  //   Svg: require('@site/static/img/illustrations/undraw/red/undraw_programmer_re_owql.svg').default,
  //   description: (
  //     <>
  //       LiRX/core can create understandable and complex data pipelines with just a few lines of code.
  //       Master data streams like a boss.
  //     </>
  //   ),
  // },
];

function Feature({title, Svg, description}: FeatureItem) {
  return (
    <div className={clsx('col col--4')}>
      <div className="text--center">
        <Svg className={styles.featureSvg} role="img" />
      </div>
      <div className="text--center padding-horiz--md">
        <h3>{title}</h3>
        <p>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures(): JSX.Element {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}
