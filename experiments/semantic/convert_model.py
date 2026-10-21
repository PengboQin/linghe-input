import pathlib,torch,numpy as np,coremltools as ct,json,time
from transformers import BertConfig,BertForMaskedLM
root=pathlib.Path(__file__).resolve().parents[2];source=root/'vendor/semantic/minirbt-h256';out=root/'artifacts/semantic';out.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(2);config=BertConfig.from_json_file(str(source/'config.json'));config._attn_implementation='eager'
model=BertForMaskedLM(config);state=torch.load(source/'pytorch_model.bin',map_location='cpu',weights_only=True);position=state.pop('bert.embeddings.position_ids',None)
if position is not None:assert torch.equal(position,torch.arange(config.max_position_embeddings).unsqueeze(0))
model.load_state_dict(state);model.eval()
class Scorer(torch.nn.Module):
 def __init__(self,model):super().__init__();self.model=model
 def forward(self,input_ids,attention_mask,position_mask,target_ids):
  hidden=self.model.bert(input_ids=input_ids,attention_mask=attention_mask).last_hidden_state
  selected=(hidden*position_mask.unsqueeze(-1)).sum(dim=1)
  logits=self.model.cls(selected)
  log_probs=torch.log_softmax(logits,dim=-1)
  return torch.gather(log_probs,1,target_ids.unsqueeze(1)).squeeze(1)
wrapper=Scorer(model).eval();batch,length=4,48
ids=torch.ones((batch,length),dtype=torch.long)*100;mask=torch.ones_like(ids);positions=torch.zeros((batch,length));positions[:,8]=1;targets=torch.ones(batch,dtype=torch.long)*100
with torch.inference_mode():trace=torch.jit.trace(wrapper,(ids,mask,positions,targets))
converted=ct.convert(trace,inputs=[ct.TensorType(name='input_ids',shape=(batch,length),dtype=np.int32),ct.TensorType(name='attention_mask',shape=(batch,length),dtype=np.int32),ct.TensorType(name='position_mask',shape=(batch,length),dtype=np.float32),ct.TensorType(name='target_ids',shape=(batch,),dtype=np.int32)],outputs=[ct.TensorType(name='log_probabilities')],minimum_deployment_target=ct.target.iOS16,convert_to='mlprogram',compute_precision=ct.precision.FLOAT16,compute_units=ct.ComputeUnit.CPU_ONLY)
converted.short_description='PrivateInput Chinese contextual masked-token scoring. HFL MiniRBT, Apache-2.0.'
converted.user_defined_metadata['upstream']='hfl/minirbt-h256@446e1b4012b10946f479563005700c54c9db3f7c'
converted.save(str(out/'SemanticScorer-fp16.mlpackage'))
from coremltools.optimize.coreml import OptimizationConfig,OpLinearQuantizerConfig,linear_quantize_weights
compressed=linear_quantize_weights(converted,config=OptimizationConfig(global_config=OpLinearQuantizerConfig(mode='linear_symmetric',dtype=np.int8)))
compressed.save(str(out/'SemanticScorer-int8.mlpackage'))
sample={'input_ids':ids.numpy().astype(np.int32),'attention_mask':mask.numpy().astype(np.int32),'position_mask':positions.numpy(),'target_ids':targets.numpy().astype(np.int32)}
start=time.monotonic();pred=compressed.predict(sample);elapsed=time.monotonic()-start
reference=wrapper(ids,mask,positions,targets).detach().numpy();error=float(np.max(np.abs(pred['log_probabilities']-reference)))
report={'batch':batch,'sequenceLength':length,'maxSyntheticNumericError':error,'warmPredictionSeconds':elapsed,'packages':{p.name:sum(f.stat().st_size for f in p.rglob('*') if f.is_file()) for p in out.glob('*.mlpackage')}}
(root/'evidence/semantic-model-20261013/conversion.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
