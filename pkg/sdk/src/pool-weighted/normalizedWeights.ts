import { BigNumber } from "@ethersproject/bignumber";
import { Zero, WeiPerEther as ONE } from "@ethersproject/constants";

export function toNormalizedWeights(weights: BigNumber[]): BigNumber[] {
  const sum = weights.reduce((total, weight) => total.add(weight), Zero);

  const normalizedWeights = [];
  let normalizedSum = Zero;
  for (let index = 0; index < weights.length; index++) {
    if (index < weights.length - 1) {
      normalizedWeights[index] = weights[index].mul(ONE).div(sum);
      normalizedSum = normalizedSum.add(normalizedWeights[index]);
    } else {
      normalizedWeights[index] = ONE.sub(normalizedSum);
    }
  }

  return normalizedWeights;
}
