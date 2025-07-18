export const description = `
Execution tests for the 'textureNumLayers' builtin function

Returns the number of layers (elements) of an array texture.
`;

import { makeTestGroup } from '../../../../../../common/framework/test_group.js';
import {
  isTextureFormatPossiblyStorageReadWritable,
  kPossibleStorageTextureFormats,
} from '../../../../../format_info.js';
import { AllFeaturesMaxLimitsGPUTest } from '../../../../../gpu_test.js';
import { kShaderStages } from '../../../../validation/decl/util.js';

import {
  executeTextureQueryAndExpectResult,
  kSampleTypeInfo,
  skipIfNoStorageTexturesInStage,
} from './texture_utils.js';

const kNumLayers = 36;

function getLayerSettingsAndExpected({
  view_type,
  isCubeArray,
}: {
  view_type: 'full' | 'partial';
  isCubeArray?: boolean;
}) {
  const divisor = isCubeArray ? 6 : 1;
  return view_type === 'partial'
    ? {
        baseArrayLayer: 11,
        arrayLayerCount: 6,
        expected: [6 / divisor],
      }
    : {
        baseArrayLayer: 0,
        arrayLayerCount: kNumLayers,
        expected: [kNumLayers / divisor],
      };
}

export const g = makeTestGroup(AllFeaturesMaxLimitsGPUTest);

g.test('sampled')
  .specURL('https://www.w3.org/TR/WGSL/#texturenumlayers')
  .desc(
    `
T, a sampled type.

fn textureNumLayers(t: texture_2d_array<T>) -> u32
fn textureNumLayers(t: texture_cube_array<T>) -> u32

Parameters
 * t The sampled array texture.
`
  )
  .params(u =>
    u
      .combine('texture_type', ['texture_2d_array', 'texture_cube_array'] as const)
      .combine('view_type', ['full', 'partial'] as const)
      .beginSubcases()
      .combine('sampled_type', ['f32', 'i32', 'u32'] as const)
      .combine('stage', kShaderStages)
  )
  .beforeAllSubcases(t => {
    t.skipIf(
      t.isCompatibility && t.params.view_type === 'partial',
      'compatibility mode does not support partial layer views'
    );
    t.skipIf(
      t.isCompatibility && t.params.texture_type === 'texture_cube_array',
      'compatibility mode does not support cube arrays'
    );
  })
  .fn(t => {
    const { stage, texture_type, sampled_type, view_type } = t.params;
    const { format } = kSampleTypeInfo[sampled_type];

    const texture = t.createTextureTracked({
      format,
      usage: GPUTextureUsage.TEXTURE_BINDING,
      size: [1, 1, kNumLayers],
    });

    const code = `
@group(0) @binding(0) var t: ${texture_type}<${sampled_type}>;
fn getValue() -> u32 {
  return textureNumLayers(t);
}
    `;

    const { baseArrayLayer, arrayLayerCount, expected } = getLayerSettingsAndExpected({
      view_type,
      isCubeArray: texture_type === 'texture_cube_array',
    });
    const viewDescription: GPUTextureViewDescriptor = {
      dimension: texture_type === 'texture_2d_array' ? '2d-array' : 'cube-array',
      baseArrayLayer,
      arrayLayerCount,
    };

    executeTextureQueryAndExpectResult(t, stage, code, texture, viewDescription, expected);
  });

g.test('arrayed')
  .specURL('https://www.w3.org/TR/WGSL/#texturenumlayers')
  .desc(
    `
fn textureNumLayers(t: texture_depth_2d_array) -> u32
fn textureNumLayers(t: texture_depth_cube_array) -> u32

Parameters
 * t The depth array texture.
`
  )
  .params(u =>
    u
      .combine('texture_type', ['texture_depth_2d_array', 'texture_depth_cube_array'] as const)
      .combine('view_type', ['full', 'partial'] as const)
      .beginSubcases()
      .combine('stage', kShaderStages)
  )
  .beforeAllSubcases(t => {
    t.skipIf(
      t.isCompatibility && t.params.view_type === 'partial',
      'compatibility mode does not support partial layer views'
    );
    t.skipIf(
      t.isCompatibility && t.params.texture_type === 'texture_depth_cube_array',
      'compatibility mode does not support cube arrays'
    );
  })
  .fn(t => {
    const { stage, texture_type, view_type } = t.params;

    const texture = t.createTextureTracked({
      format: 'depth32float',
      usage: GPUTextureUsage.TEXTURE_BINDING,
      size: [1, 1, kNumLayers],
    });

    const code = `
@group(0) @binding(0) var t: ${texture_type};
@group(0) @binding(1) var<storage, read_write> result: u32;
fn getValue() -> u32 {
  return textureNumLayers(t);
}
    `;

    const { baseArrayLayer, arrayLayerCount, expected } = getLayerSettingsAndExpected({
      view_type,
      isCubeArray: texture_type === 'texture_depth_cube_array',
    });
    const viewDescription: GPUTextureViewDescriptor = {
      dimension: texture_type === 'texture_depth_2d_array' ? '2d-array' : 'cube-array',
      baseArrayLayer,
      arrayLayerCount,
    };

    executeTextureQueryAndExpectResult(t, stage, code, texture, viewDescription, expected);
  });

g.test('storage')
  .specURL('https://www.w3.org/TR/WGSL/#texturenumlayers')
  .desc(
    `
F: rgba8unorm
   rgba8snorm
   rgba8uint
   rgba8sint
   rgba16uint
   rgba16sint
   rgba16float
   r32uint
   r32sint
   r32float
   rg32uint
   rg32sint
   rg32float
   rgba32uint
   rgba32sint
   rgba32float
A: read, write, read_write

fn textureNumLayers(t: texture_storage_2d_array<F,A>) -> u32

Parameters
 * t The sampled storage array texture.
`
  )
  .params(u =>
    u
      .combine('format', kPossibleStorageTextureFormats)
      .combine('view_type', ['full', 'partial'] as const)
      .beginSubcases()
      .combine('stage', kShaderStages)
      .combine('access_mode', ['read', 'write', 'read_write'] as const)
      .filter(
        t => t.access_mode !== 'read_write' || !isTextureFormatPossiblyStorageReadWritable(t.format)
      )
      // Vertex stage can not use writable storage textures.
      .unless(t => t.stage === 'vertex' && t.access_mode !== 'read')
  )
  .beforeAllSubcases(t => {
    t.skipIf(
      t.isCompatibility && t.params.view_type === 'partial',
      'compatibility mode does not support partial layer views'
    );
  })
  .fn(t => {
    const { stage, format, access_mode, view_type } = t.params;
    skipIfNoStorageTexturesInStage(t, stage);
    t.skipIfTextureFormatNotSupported(format);
    t.skipIfTextureFormatNotUsableAsStorageTexture(format);
    if (access_mode === 'read_write') {
      t.skipIfTextureFormatNotUsableAsReadWriteStorageTexture(format);
    }

    const texture = t.createTextureTracked({
      format,
      usage: GPUTextureUsage.STORAGE_BINDING,
      size: [1, 1, kNumLayers],
    });

    const code = `
@group(0) @binding(0) var t: texture_storage_2d_array<${format}, ${access_mode}>;
@group(0) @binding(1) var<storage, read_write> result: u32;
fn getValue() -> u32 {
  return textureNumLayers(t);
}
    `;

    const { baseArrayLayer, arrayLayerCount, expected } = getLayerSettingsAndExpected({
      view_type,
    });
    const viewDescription: GPUTextureViewDescriptor = {
      dimension: '2d-array',
      baseArrayLayer,
      arrayLayerCount,
    };

    executeTextureQueryAndExpectResult(t, stage, code, texture, viewDescription, expected);
  });
