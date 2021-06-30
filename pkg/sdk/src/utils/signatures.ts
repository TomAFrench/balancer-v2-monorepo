import { MaxUint256 as MAX_DEADLINE } from '@ethersproject/constants';
import { Contract } from "@ethersproject/contracts"
import { hexValue, hexZeroPad, splitSignature} from "@ethersproject/bytes"
import { BigNumberish } from '@ethersproject/bignumber';
import { TypedDataSigner } from '@ethersproject/abstract-signer';

export enum RelayerAction {
  JoinPool = "JoinPool",
  ExitPool = "ExitPool",
  Swap = "Swap",
  BatchSwap = "BatchSwap",
  SetRelayerApproval = "SetRelayerApproval",
}

export function encodeCalldataAuthorization(calldata: string, deadline: BigNumberish, signature: string): string {
  const encodedDeadline = hexZeroPad(hexValue(deadline), 32).slice(2);
  const { v, r, s } = splitSignature(signature);
  const encodedV = hexZeroPad(hexValue(v), 32).slice(2);
  const encodedR = r.slice(2);
  const encodedS = s.slice(2);
  return `${calldata}${encodedDeadline}${encodedV}${encodedR}${encodedS}`;
}

export async function signJoinAuthorization(
  validator: Contract,
  user: TypedDataSigner,
  allowedSender: string,
  allowedCalldata: string,
  nonce: BigNumberish,
  deadline?: BigNumberish
): Promise<string> {
  return signAuthorizationFor(RelayerAction.JoinPool, validator, user, allowedSender, allowedCalldata, nonce, deadline);
}

export async function signExitAuthorization(
  validator: Contract,
  user: TypedDataSigner,
  allowedSender: string,
  allowedCalldata: string,
  nonce: BigNumberish,
  deadline?: BigNumberish
): Promise<string> {
  return signAuthorizationFor(RelayerAction.ExitPool, validator, user, allowedSender, allowedCalldata, nonce, deadline);
}

export async function signSwapAuthorization(
  validator: Contract,
  user: TypedDataSigner,
  allowedSender: string,
  allowedCalldata: string,
  nonce: BigNumberish,
  deadline?: BigNumberish
): Promise<string> {
  return signAuthorizationFor(RelayerAction.Swap, validator, user, allowedSender, allowedCalldata, nonce, deadline);
}

export async function signBatchSwapAuthorization(
  validator: Contract,
  user: TypedDataSigner,
  allowedSender: string,
  allowedCalldata: string,
  nonce: BigNumberish,
  deadline?: BigNumberish
): Promise<string> {
  return signAuthorizationFor(RelayerAction.BatchSwap, validator, user, allowedSender, allowedCalldata, nonce, deadline);
}

export async function signSetRelayerApprovalAuthorization(
  validator: Contract,
  user: TypedDataSigner,
  allowedSender: string,
  allowedCalldata: string,
  nonce: BigNumberish,
  deadline?: BigNumberish
): Promise<string> {
  return signAuthorizationFor(RelayerAction.SetRelayerApproval, validator, user, allowedSender, allowedCalldata, nonce, deadline);
}

export async function signAuthorizationFor(
  type: RelayerAction,
  validator: Contract,
  user: TypedDataSigner,
  allowedSender: string,
  allowedCalldata: string,
  nonce: BigNumberish,
  deadline: BigNumberish = MAX_DEADLINE
): Promise<string> {
  const { chainId } = await validator.provider.getNetwork();

  const domain = {
    name: 'Balancer V2 Vault',
    version: '1',
    chainId,
    verifyingContract: validator.address,
  };

  
  const types = {
    [type]: [
      { name: 'calldata', type: 'bytes' },
      { name: 'sender', type: 'address' },
      { name: 'nonce', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
    ],
  };

  const value = {
    calldata: allowedCalldata,
    sender: allowedSender,
    nonce: nonce.toString(),
    deadline: deadline.toString(),
  };

  return user._signTypedData(domain, types, value);
}