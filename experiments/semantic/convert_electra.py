import pathlib,torch,numpy as np,coremltools as ct,json,time
from transformers import ElectraConfig,ElectraForPreTraining,BertTokenizer
root=pathlib.Path(__file__).resolve().parents[2];source=root/'vendor/semantic/electra-small';out=root/'artifacts/semantic';out.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(2);config=ElectraConfig.from_json_file(str(source/'config.json'));config._attn_implementation='eager'
model=ElectraForPreTraining(config);state=torch.load(source/'pytorch_model.bin',map_location='cpu',weights_only=True);position=state.pop('electra.embeddings.position_ids',None)
if position is not None:assert torch.equal(position,torch.arange(config.max_position_embeddings).unsqueeze(0))
model.load_state_dict(state);model.eval();tokenizer=BertTokenizer(vocab_file=str(source/'vocab.txt'),do_lower_case=True)
class Scorer(torch.nn.Module):
 def __init__(self,model):super().__init__();self.model=model
 def forward(self,input_ids,attention_mask):
  # HF builds an attention bias with float32.min; fp16 conversion turns it
  # into infinity and 0*infinity creates NaNs. Use a finite equivalent mask.
  hidden=self.model.electra.embeddings(input_ids=input_ids)
  if hasattr(self.model.electra,'embeddings_project'):hidden=self.model.electra.embeddings_project(hidden)
  bias=(1-attention_mask[:,None,None,:].float())*-10000.0
  hidden=self.model.electra.encoder(hidden,attention_mask=bias,return_dict=False)[0]
  return self.model.discriminator_predictions(hidden)
wrapper=Scorer(model).eval();batch,length=4,48
sample=tokenizer(['我想喝水','我想和税','今天下午我们一起吃饭','今天下午我们一起吃反'],padding='max_length',max_length=length,truncation=True,return_tensors='pt');ids=sample['input_ids'];mask=sample['attention_mask']
with torch.inference_mode():trace=torch.jit.trace(wrapper,(ids,mask))
# Keep normalization in fp32: the checkpoint uses an epsilon below fp16 range.
precision=ct.transform.FP16ComputePrecision(op_selector=lambda op:op.op_type!='layer_norm')
converted=ct.convert(trace,inputs=[ct.TensorType(name='input_ids',shape=(batch,length),dtype=np.int32),ct.TensorType(name='attention_mask',shape=(batch,length),dtype=np.int32)],outputs=[ct.TensorType(name='replacement_logits',dtype=np.float32)],minimum_deployment_target=ct.target.iOS16,convert_to='mlprogram',compute_precision=precision,compute_units=ct.ComputeUnit.CPU_ONLY)
converted.short_description='Chinese contextual token plausibility. HFL ELECTRA small discriminator, Apache-2.0.'
converted.user_defined_metadata['upstream']='hfl/chinese-electra-180g-small-discriminator@826a243f3f387450ef8d70de9c3d0706d8d8e924'
converted.save(str(out/'SemanticDiscriminator-fp16.mlpackage'))
from coremltools.optimize.coreml import OptimizationConfig,OpLinearQuantizerConfig,linear_quantize_weights
compressed=linear_quantize_weights(converted,config=OptimizationConfig(global_config=OpLinearQuantizerConfig(mode='linear_symmetric',dtype=np.int8)))
compressed.save(str(out/'SemanticDiscriminator-int8.mlpackage'))
inputs={'input_ids':ids.numpy().astype(np.int32),'attention_mask':mask.numpy().astype(np.int32)}
start=time.monotonic();pred=compressed.predict(inputs)['replacement_logits'];first=time.monotonic()-start
with torch.inference_mode():reference=wrapper(ids,mask).numpy()
assert np.isfinite(pred).all(),'Converted model must be finite'
with torch.inference_mode():
 original=model(ids,attention_mask=mask).logits.numpy()
 assert np.max(np.abs(wrapper(ids,mask).numpy()-original))<0.001,'Finite attention mask changes original model output'
error=float(np.max(np.abs(pred-reference)));times=[]
for _ in range(5):
 start=time.monotonic();compressed.predict(inputs);times.append(time.monotonic()-start)
report={'batch':batch,'sequenceLength':length,'maxRealTextLogitError':error,'firstPredictionSeconds':first,'warmPredictionSeconds':times,'packages':{p.name:sum(f.stat().st_size for f in p.rglob('*') if f.is_file()) for p in out.glob('SemanticDiscriminator*.mlpackage')}}
(root/'evidence/semantic-model-20261013/electra-conversion.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
