import { expect } from 'chai';

import Task from '../../../src/task';
import { Output } from '../../../src/types';

describe('StablePool', function () {
  const task = new Task('20210624-stable-pool', 'mainnet');
  task.outputFile = 'test';

  afterEach('delete deployment', async () => {
    await task.delete();
  });

  context('with no previous deploy', () => {
    const itDeploysFactory = (force: boolean) => {
      it('deploys a stable pool factory', async () => {
        await task.run(force);

        const output = task.output();
        expect(output.factory).not.to.be.null;
        expect(output.timestamp).not.to.be.null;

        const input = task.input();
        const factory = await task.instanceAt('StablePoolFactory', output.factory);
        expect(await factory.getVault()).to.be.equal(input.vault);
      });
    };

    context('when forced', () => {
      const force = true;

      itDeploysFactory(force);
    });

    context('when not forced', () => {
      const force = false;

      itDeploysFactory(force);
    });
  });

  context('with a previous deploy', () => {
    let previousDeploy: Output;

    beforeEach('deploy', async () => {
      await task.run();
      previousDeploy = task.output();
    });

    context('when forced', () => {
      const force = true;

      it('re-deploys the stable pool factory', async () => {
        await task.run(force);

        const output = task.output();
        expect(output.factory).not.to.be.equal(previousDeploy.factory);
        expect(output.timestamp).to.be.gt(previousDeploy.timestamp);
      });
    });

    context('when not forced', () => {
      const force = false;

      it('does not re-deploys the stable pool factory', async () => {
        await task.run(force);

        const output = task.output();
        expect(output.factory).to.be.equal(previousDeploy.factory);
        expect(output.timestamp).to.be.equal(previousDeploy.timestamp);
      });
    });
  });
});
