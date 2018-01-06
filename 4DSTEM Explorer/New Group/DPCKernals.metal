//
//  DPCKernals.metal
//  4DSTEM Explorer
//
//  Created by James LeBeau on 1/5/18.
//  Copyright © 2018 The LeBeau Group. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

kernel void filter_main(
                        texture2d<float,access::read>   inputImage   [[ texture(0) ]],
                        texture2d<float,access::write>  outputImage  [[ texture(1) ]],
                        uint2 gid                                    [[ thread_position_in_grid ]],
                        texture2d<float,access::sample> table        [[ texture(2) ]]                        )
{
    float2 p0          = static_cast<float2>(gid);
    
    float4 v0 = read_and_transform(inputImage, p0, transform);
    float4 v1 = filter_table(v0,table, dims);
    
    outputImage.write(v1,gid);
}

kernel void read_and_transform( texture2d<float,access::read>   inputImage   [[ texture(0) ]]
                               ){
    
}

